# Experiment to stress the GC with multi-threading.
# The experiment manually allocates multiple times a queue of fibers
# on a list of worker threads. The main thread does the orchestration.
# The fibers will grow and shrink their stack size by doing recursion.
# In each level of the stack an amount of dummy objects are allocated.
# These objects will be released by the GC eventually.

lib LibC
  fun fflush(b : Void*)
end

def __p(s)
  t = Thread.current.to_s rescue "Unknown"
  f = Fiber.current.to_s rescue "Unknown"
  LibC.printf("%s::%s >>> %s\n", t, f, s)
  LibC.fflush(nil)
  s
end

class Foo
  @@collections = Atomic(Int32).new(0)

  @data = StaticArray(Int32, 8).new(0)

  def finalize
    @@collections.add(1)
  end

  def self.collections
    @@collections.get
  end
end

class Context
  property expected_depth : Int32 = 0
  @worker_fibers = Array(Fiber).new(0)
  @pending_fibers = Array(Fiber).new(0)

  def initialize(@fibers : Int32, @threads : Int32)
    @fibers_reached = Atomic(Int32).new(0)
    @fiber_depths = Array(Int32).new(@fibers, 0)
    @mutex = Thread::Mutex.new
    @threads_state = :wait

    # Create worker fibers but do not start them yet.
    # Each fiber will try to reach the `expected_depth` value
    # by increasing or decreasing its callstack.
    @fibers.times do |index|
      @worker_fibers << Fiber.new("f:#{index}") do
        Context.fiber_run(self, index, 1)
      end
    end

    # Create worker threads.
    # they will perform operations when `@threads_state == :run`
    # otherwise they will remain in a tight busy loop.
    # See Context#create_thread
    @threads.times { create_thread }
  end

  def self.fiber_run(context, fiber_index, depth)
    context.set_fiber_depth(fiber_index, depth)

    # allocate a bunch of objects in the stack
    # some should be released fast
    10.times do
      foo = Foo.new
    end
    foo = Foo.new

    # increase/decrease stack depending on the expected_depth
    # when reached, notify and yield control
    while true
      if context.expected_depth < depth
        return
      elsif context.expected_depth > depth
        fiber_run(context, fiber_index, depth + 1)
      else
        context.notifify_depth_reached
        context.yield
      end
    end
  end

  def set_fiber_depth(index, depth)
    @fiber_depths[index] = depth
  end

  def run_until_depth(phase, depth)
    # make all fibers reach a specific depth
    __p "#{phase}: expected_depth: #{depth}"

    @expected_depth = depth
    @fibers_reached.set(0)
    @pending_fibers = @worker_fibers.dup.shuffle!
    @threads_state = :run

    # spin wait for all fibers to finish
    while @fibers_reached.get < @fibers
    end
    __p "All fibers_reached!"

    @threads_state = :wait
  end

  def notifify_depth_reached
    @fibers_reached.add(1)
  end

  def yield
    Thread.current.main_fiber.resume
  end

  def pick_and_resume_fiber
    fiber = nil

    @mutex.synchronize do
      fiber = @pending_fibers.shift?
    end

    # __p "Picking #{fiber}"

    fiber.resume if fiber
  end

  def gc_stats
    __p "GC.stats: #{GC.stats}"
    __p "Foo.collections: #{Foo.collections}"
  end

  def create_thread
    Thread.new do
      while true
        case @threads_state
        when :run
          pick_and_resume_fiber
        end
      end
    end
  end
end

# Specify the number of fibers and threads to use
context = Context.new(fibers: 1_000, threads: 4)

(1..20).each do |i|
  context.run_until_depth "Phase #{i}.1", 40
  context.run_until_depth "Phase #{i}.2", 5

  context.gc_stats
  # GC.collect
  # context.gc_stats

  context.run_until_depth "Phase #{i}.3", 50
  context.run_until_depth "Phase #{i}.4", 5

  context.gc_stats

  context.run_until_depth "Phase #{i}.5", 10

  context.gc_stats
  # GC.collect
  # context.gc_stats
end
__p "Done"