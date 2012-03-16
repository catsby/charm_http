class CharmHttp
  class Benchmark
    class NoInstances < RuntimeError
    end

    def self.run(paths, hostnames, dyno_min, dyno_max, buckets, requests_per_connection)
      targets = paths.split(',').zip(hostnames.split(','))
      instances = CharmHttp.instances

      raise NoInstances if instances.empty?
      reset(instances)

      results = {}

      targets.each do |path, hostname|
        (dyno_min..dyno_max).each do |dynos|
          scale(path, dynos)

          # Find optimal concurrency
          concurrency, prev_hz, hz = 10, 0, 1
          step = 10

          while hz > prev_hz
            concurrency += step
            prev_hz = hz
            hz = parallel_test(instances, hostname, (concurrency * dynos / instances).to_i, 10, buckets, requests_per_connection, true)["hz"]
            print "#{concurrency}->#{hz} ... "
          end
          concurrency -= step
          puts

          # Measure
          results[hostname] ||= {}
          results[hostname][dynos] = parallel_test(instances, hostname, (concurrency * dynos / instances).to_i, 60, buckets, requests_per_connection)
        end

        File.write(hostname, results.inspect)

        reset(instances)
        scale(path, 1)
      end
    end

    def self.reset(instances)
      instances.each do |instance|
        CharmHttp.ssh(instance, "killall hstress || true")
      end
    end

    def self.parallel_test(instances, *args)
      results = Hash.new(0)
      threads = []
      instances.each do |instance|
        threads << Thread.new do
          h = test(instance, *args)
          h.each {|k,v| results[k] += v }
        end
      end
      threads.each(&:join)
      results
    end

    def self.test(instance, hostname, concurrency, seconds, buckets, requests_per_connection, quiet = false)
      results = {}
      value = CharmHttp.ssh(instance, "hummingbird/hstress -c #{concurrency} -b #{buckets} -p 1 -r #{requests_per_connection} -i 1 #{hostname} 80", seconds, quiet)
      values = value[/(successes.*)/m, 1].split('#')
      values.map! {|v| v.split(/\s+/)}
      values.each {|v| v.reject!(&:empty?) }
      values.each {|k, v, p| results[k] = v.to_i}
      results
    end

    def self.scale(path, dynos)
      CharmHttp.run("cd #{path} && heroku restart && heroku ps:scale web=#{dynos}")
    end

  end
end
