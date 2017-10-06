# frozen_string_literal: true
require_relative '../test_helper'

SingleCov.covered!

describe JobQueue do
  # JobExecution is slow/complicated ... so we stub it out
  fake_execution = Class.new do
    attr_reader :id
    def initialize(id)
      @id = id
    end

    # when expectations fail we need to know what failed
    def inspect
      "job-#{id}"
    end
  end

  def wait_for_jobs_to_finish
    sleep 0.01 until subject.debug == [{}, {}]
  end

  def with_executing_job
    job_execution.expects(:perform).with { active_lock.synchronize { true } }

    with_job_execution do
      locked do
        subject.add(job_execution)
        yield
      end
    end
  end

  def with_a_queued_job
    # keep executing until unlocked
    job_execution.expects(:perform).with { active_lock.synchronize { true } }
    queued_job_execution.expects(:perform).with { queued_lock.synchronize { true } }

    with_job_execution do
      locked do
        subject.add(job_execution, queue: queue_name)
        subject.add(queued_job_execution, queue: queue_name)
        yield
      end
    end
  end

  def locked
    locks = [active_lock, queued_lock]
    locks.each(&:lock) # stall jobs

    yield

    # let jobs finish
    locks.each { |l| l.unlock if l.locked? }
    wait_for_jobs_to_finish
  end

  let(:subject) { JobQueue.new }
  let(:job_execution) { fake_execution.new(:active) }
  let(:queued_job_execution) { fake_execution.new(:queued) }
  let(:active_lock) { Mutex.new }
  let(:queued_lock) { Mutex.new }
  let(:queue_name) { :my_queue }

  before do
    JobExecution.stubs(:new).returns(job_execution).returns(queued_job_execution)
  end

  describe "#add" do
    it 'immediately performs a job when executing is empty' do
      with_executing_job do
        assert subject.executing?(:active)
        refute subject.queued?(:active)
        subject.find_by_id(:active).must_equal(job_execution)
      end
    end

    it 'performs parallel jobs when they are in different queues' do
      locked do
        [job_execution, queued_job_execution].each do |job|
          job.expects(:perform).with { active_lock.synchronize { true } }

          with_job_execution { subject.add(job) }

          assert subject.executing?(job.id)
        end
      end
    end

    it 'does not perform a job if job execution is disabled' do
      JobExecution.enabled = false
      job_execution.expects(:perform).never

      subject.add(job_execution)

      refute subject.executing?(:active)
      refute subject.queued?(:active)
      refute subject.find_by_id(:active)
    end

    it 'does not queue a job if job execution is disabled' do
      with_executing_job do
        JobExecution.enabled = false
        subject.add(queued_job_execution, queue: queue_name)

        refute subject.executing?(:queued)
        refute subject.queued?(:queued)
        refute subject.find_by_id(:queued)
      end
    end

    it 'reports to airbrake when executing jobs were in an unexpected state' do
      with_job_execution do
        subject.instance_variable_get(:@executing)[queue_name] = job_execution

        e = assert_raises RuntimeError do
          subject.send(:delete_and_enqueue_next, queued_job_execution, queue_name)
        end
        e.message.must_equal 'Unexpected executing job found in queue my_queue: expected queued got active'
      end
    end

    it 'reports queue length' do
      states = [
        [1, 0], # add active
        [1, 1], # add queued
        [1, 0], # done active ... enqueue queued
        [0, 0], # done queued
      ]
      states.each do |t, q|
        ActiveSupport::Notifications.expects(:instrument).with("job_queue.samson", threads: t, queued: q)
      end
      with_a_queued_job {} # noop
    end

    describe 'with queued job' do
      it 'has a queued job' do
        with_a_queued_job do
          refute subject.executing?(:queued)
          assert subject.queued?(:queued)
          subject.find_by_id(:queued).must_equal(queued_job_execution)
        end
      end

      it 'performs then next job when executing job completes' do
        with_a_queued_job do
          active_lock.unlock
          sleep 0.01 while subject.executing?(:active)

          refute subject.find_by_id(:active)
          assert subject.executing?(:queued)
          refute subject.queued?(:queued)
        end
      end

      it 'does not perform the next job when job execution is disabled' do
        with_a_queued_job do
          JobExecution.enabled = false

          queued_job_execution.unstub(:perform)
          queued_job_execution.expects(:perform).never

          active_lock.unlock
          sleep 0.01 while subject.executing?(:active)

          refute subject.find_by_id(:active)
          refute subject.executing?(:queued)
          assert subject.queued?(:queued)
          subject.debug.each(&:clear)
        end
      end

      it 'does not fail when queue is empty' do
        with_a_queued_job do
          active_lock.unlock
          queued_lock.unlock
          wait_for_jobs_to_finish

          refute subject.find_by_id(:active)
          refute subject.find_by_id(:queued)

          # make sure we cleaned up nicely
          subject.instance_variable_get(:@executing).must_equal({})
          subject.instance_variable_get(:@queue).must_equal({})
        end
      end
    end
  end

  describe "#dequeue" do
    it "removes a job from the queue" do
      with_a_queued_job do
        queued_job_execution.unstub(:perform)
        assert subject.dequeue(queued_job_execution.id)
        refute subject.queued?(queued_job_execution.id)
      end
    end

    it "does not remove a job when it is not queued" do
      with_a_queued_job do
        refute subject.dequeue(job_execution.id)
        refute subject.queued?(job_execution.id)
      end
    end
  end

  describe "#debug" do
    it "returns executing and queued" do
      subject.debug.must_equal([{}, {}])
    end
  end
end
