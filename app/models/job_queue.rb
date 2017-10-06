# frozen_string_literal: true
# make jobs with the same queue run in serial and track their status
class JobQueue
  LOCK = Mutex.new

  def initialize
    @queue = Hash.new { |h, q| h[q] = [] }
    @executing = {}
  end

  def executing
    @executing.values
  end

  def executing?(id)
    executing.detect { |je| je.id == id }
  end

  def queued?(id)
    @queue.values.detect { |jes| jes.detect { |je| return je if je.id == id } }
  end

  def dequeue(id)
    !!@queue.values.detect { |jes| jes.reject! { |je| je.id == id } }
  end

  def find_by_id(id)
    LOCK.synchronize { executing?(id) || queued?(id) }
  end

  # when no queue is given jobs run in parallel (each in their own queue) and start instantly
  # when samson is restarting we do not start jobs, but leave them pending
  def add(job_execution, queue: nil)
    queue ||= job_execution.id

    LOCK.synchronize do
      if JobExecution.enabled
        if @executing[queue]
          @queue[queue] << job_execution
        else
          perform_job(job_execution, queue)
        end
      end
    end

    instrument
  end

  def debug
    [@executing, @queue]
  end

  private

  def perform_job(job_execution, queue)
    @executing[queue] = job_execution
    Thread.new do
      begin
        job_execution.perform
      ensure
        delete_and_enqueue_next(job_execution, queue)
      end
    end
  end

  def delete_and_enqueue_next(job_execution, queue)
    LOCK.synchronize do
      previous = @executing.delete(queue)
      unless job_execution == previous
        raise "Unexpected executing job found in queue #{queue}: expected #{job_execution&.id} got #{previous&.id}"
      end

      if JobExecution.enabled && (job_execution = @queue[queue].shift)
        perform_job(job_execution, queue)
      end

      @queue.delete(queue) if @queue[queue].empty? # save memory, and time when iterating all queues
    end

    instrument
  end

  def instrument
    ActiveSupport::Notifications.instrument(
      "job_queue.samson",
      threads: @executing.length,
      queued: @queue.values.sum(&:count)
    )
  end
end
