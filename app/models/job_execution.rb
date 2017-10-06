# frozen_string_literal: true
require 'shellwords'

class JobExecution
  include ::NewRelic::Agent::Instrumentation::ControllerInstrumentation

  # Whether or not execution is enabled. This allows completely disabling job
  # execution for testing purposes and when restarting samson.
  class << self
    attr_accessor :enabled
  end

  cattr_accessor(:cancel_timeout, instance_writer: false) { 15.seconds }

  attr_reader :output, :reference, :job, :viewers, :executor

  delegate :id, to: :job
  delegate :pid, :pgid, to: :executor

  def initialize(reference, job, env: {}, output: OutputBuffer.new, &block)
    @output = output
    @executor = TerminalExecutor.new(@output, verbose: true, deploy: job.deploy, project: job.project)
    @viewers = JobViewers.new(@output)

    @start_callbacks = []
    @finish_callbacks = []
    @env = env
    @job = job
    @reference = reference
    @execution_block = block
    @cancelled = false
    @finished = false
    @thread = nil

    @repository = @job.project.repository
    @repository.executor = @executor

    on_finish do
      # weird issue we are seeing with docker builds never finishing
      if !Rails.env.test? && !JobExecution.find_by_id(@job.id) && @job.active?
        Airbrake.notify("Active but not running job found", job: @job.id)
        @output.write("Active but not running job found")
        @job.failed!
      end

      @output.write('', :finished)
      @output.close

      @job.update_output!(OutputAggregator.new(@output).to_s)
    end
  end

  def perform
    @thread = Thread.current
    ActiveRecord::Base.connection_pool.with_connection { run }
  end

  def wait
    @thread.join
  end

  # Used on queued jobs when shutting down
  # so that the stream sockets are closed
  def close
    @output.write('', :reloaded)
    @output.close
  end

  def cancel
    @cancelled = true
    @job.cancelling!
    @executor.cancel 'INT'
    unless @thread.join(cancel_timeout)
      @executor.cancel 'KILL'
      @thread.join(cancel_timeout) || @thread.kill
    end
    @job.cancelled!
    finish
  end

  def on_start(&block)
    @start_callbacks << block
  end

  def on_finish(&block)
    @finish_callbacks << JobExecutionSubscriber.new(job, &block)
  end

  def descriptor
    "#{job.project.name} - #{reference}"
  end

  def base_commands(dir, env = {})
    artifact_cache_dir = File.join(@job.project.repository.repo_cache_dir, "artifacts")
    FileUtils.mkdir_p(artifact_cache_dir)

    env = {
      PROJECT_NAME: @job.project.name,
      PROJECT_PERMALINK: @job.project.permalink,
      PROJECT_REPOSITORY: @job.project.repository_url,
      CACHE_DIR: artifact_cache_dir
    }.merge(env)

    commands = env.map do |key, value|
      "export #{key}=#{value.to_s.shellescape}"
    end

    ["cd #{dir}"].concat commands
  end

  private

  def stage
    @job.deploy.try(:stage)
  end

  def error!(exception)
    puts_if_present report_to_airbrake(exception)
    puts_if_present "JobExecution failed: #{exception.message}"
    puts_if_present render_backtrace(exception)
    @job.errored! if @job.active?
  end

  def run
    @output.write('', :started)
    @start_callbacks.each(&:call)
    @job.running!

    success = make_tempdir do |dir|
      return @job.errored! unless setup(dir)

      if @execution_block
        @execution_block.call(self, dir)
      else
        execute(dir)
      end
    end

    if success
      @job.succeeded!
    else
      @job.failed!
    end

  # when thread was killed by 'cancel' it is in a bad state, avoid working
  rescue => e
    error!(e) unless @cancelled
  ensure
    finish unless @cancelled
  end
  add_transaction_tracer :run,
    category: :task,
    params: '{ job_id: id, project: job.project.try(:name), reference: reference }'

  def finish
    return if @finished
    @finished = true
    @finish_callbacks.each(&:call)
  end

  def execute(dir)
    Samson::Hooks.fire(:after_deploy_setup, dir, @job, @output, @reference)

    @output.write("\n# Executing deploy\n")
    @output.write("# Deploy URL: #{@job.deploy.url}\n") if @job.deploy

    cmds = commands(dir)
    payload = {
      stage: (stage&.name || "none"),
      project: @job.project.name,
      production: stage&.production?
    }

    ActiveSupport::Notifications.instrument("execute_job.samson", payload) do
      payload[:success] =
        if defined?(Kubernetes::DeployExecutor) && stage&.kubernetes
          @executor = Kubernetes::DeployExecutor.new(@output, job: @job, reference: @reference)
          @executor.execute
        else
          @executor.execute(*cmds)
        end
    end

    Samson::Hooks.fire(:after_job_execution, @job, payload[:success], @output)

    payload[:success]
  end

  def setup(dir)
    return unless resolve_ref_to_commit
    stage.try(:kubernetes) || @repository.checkout_workspace(dir, @reference)
  end

  def resolve_ref_to_commit
    commit = @repository.commit_from_ref(@reference)
    tag = @repository.fuzzy_tag_from_ref(@reference)
    if commit
      @job.update_git_references!(commit: commit, tag: tag)
      @output.puts("Commit: #{commit}")
      true
    else
      @output.puts("Could not find commit for #{@reference}")
      false
    end
  end

  def commands(dir)
    env = {
      DEPLOY_URL: @job.url,
      DEPLOYER: @job.user.email,
      DEPLOYER_EMAIL: @job.user.email,
      DEPLOYER_NAME: @job.user.name,
      REFERENCE: @reference,
      REVISION: @job.commit,
      TAG: (@job.tag || @job.commit)
    }.merge(@env)

    if deploy = @job.deploy
      env[:COMMIT_RANGE] = deploy.changeset.commit_range
    end

    env.merge!(Hash[*Samson::Hooks.fire(:job_additional_vars, @job)])

    base_commands(dir, env) + @job.commands
  end

  # show full errors if we show exceptions
  def render_backtrace(exception)
    return unless Rails.application.config.consider_all_requests_local
    backtrace = Rails.backtrace_cleaner.filter(exception.backtrace).first(10)
    backtrace << '...'
    backtrace.join("\n")
  end

  def report_to_airbrake(exception)
    return if exception.is_a?(Samson::Hooks::UserError) # do not spam us with users issues

    return unless notice = Airbrake.notify_sync(
      exception,
      error_message: exception.message,
      parameters: {job_id: @job.id}
    )

    return 'Airbrake did not return an error id' unless id = notice['id']
    return 'Unable to find Airbrake url' unless url = Airbrake.user_information[/['"](http.*?)['"]/, 1]
    return 'Unable to find error_id placeholder' unless url.sub!('{{error_id}}', id)
    "Error #{url}"
  end

  def puts_if_present(message)
    @output.puts message if message
  end

  def make_tempdir
    result = nil
    Dir.mktmpdir("samson-#{@job.project.permalink}-#{@job.id}") do |dir|
      result = yield dir
    end
  rescue Errno::ENOTEMPTY, Errno::ENOENT
    Airbrake.notify("Notify: make_tempdir error #{$!.message.split('@').first}")
    result # tempdir ensure sometimes fails ... not sure why ... return normally
  end

  class << self
    def find_by_id(id)
      job_queue.find_by_id(id)
    end

    def executing?(id)
      job_queue.executing?(id)
    end

    def queued?(id)
      job_queue.queued?(id)
    end

    def dequeue(id)
      job_queue.dequeue(id)
    end

    def perform_later(*args)
      job_queue.add(*args)
    end

    def executing
      job_queue.executing
    end

    def debug
      job_queue.debug
    end

    private

    def job_queue
      @job_queue ||= JobQueue.new
    end
  end
end
