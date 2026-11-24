# frozen_string_literal: true

require "open3"
require "timeout"

module Ancora
  # Subprocess seam: every command ancora runs goes through #run, so a
  # runtime can swap in another executor and specs stay offline. Commands
  # are argv arrays (no shell interpolation) or a string for `sh -c`
  # (chain.yml gate/canary commands are shell strings).
  class Shell
    Result = Struct.new(:ok, :output, :timed_out, keyword_init: true) do
      def ok?
        ok
      end
    end

    def run(command, chdir:, env: {}, timeout: nil)
      argv = command.is_a?(Array) ? command : ["sh", "-c", command]
      capture(argv, chdir, env, timeout)
    rescue SystemCallError => e
      Result.new(ok: false, output: e.message, timed_out: false)
    end

    private

    def capture(argv, chdir, env, timeout)
      options = { chdir: chdir, pgroup: true }
      Open3.popen2e(env, *argv, **options) do |stdin, out, wait|
        stdin.close
        output = []
        reader = Thread.new { out.each_line { |l| output << l } }
        timed_out = wait.join(timeout).nil?
        terminate(wait) if timed_out
        reader.join(5)
        result(wait, output, timed_out)
      end
    end

    def result(wait, output, timed_out)
      Result.new(ok: !timed_out && wait.value.success?,
                 output: output.join, timed_out: timed_out)
    end

    def terminate(wait)
      Process.kill("TERM", -wait.pid)
      Process.kill("KILL", -wait.pid) if wait.join(5).nil?
    rescue Errno::ESRCH
      nil
    end
  end
end
