# frozen_string_literal: true

module Ancora
  # Runs a gate recipe: the GateLock full-set compile, gem suites and canary
  # corpus gate. It never publishes; every subprocess goes through the
  # injected shell, so specs and dry runs stay offline.
  #
  #   1. lock    - write the Gemfile pinning the ENTIRE candidate set
  #   2. compile - `bundle lock` then `bundle install` against that lock:
  #                conflicting floors or a missing candidate fail here
  #   3. suites  - chain.yml gate commands in each gem's main checkout,
  #                using the GateLock Gemfile for the candidate set
  #   4. canary  - chain.yml canary commands, run once per configured
  #                corpus checkout (documents in ANCORA_CORPUS_DOCUMENTS,
  #                the corpus budget as the timeout), or once in the lock
  #                directory when the chain configures no corpus
  #
  # The verdict is green only when every step passed. A failed compile
  # skips suites and canary; a failed suite skips canary and names its gem
  # as suspect. A red corpus names the gems it gates, as the
  # suspects of the next attempt. The engine enforces only the configured
  # corpora; it never infers coverage.
  class GateRun
    Step = Struct.new(:name, :kind, :status, :detail, :gems,
                      keyword_init: true)
    Verdict = Struct.new(:result, :steps, :suspects, keyword_init: true) do
      def green?
        result == "green"
      end
    end

    class Refused < StandardError; end

    # a suite or canary command that would publish is a config error, never run
    PUBLISHING = Regexp.union(
      /\bgem\b.*\bpush\b/, /rubygems-release/,
      /\bgh\b.*\b(?:release|workflow)\b/, /\bgit\b.*\b(?:push|tag)\b/,
      /\brake\b.*\brelease\b/
    )

    # suite and canary commands never see publishing credentials (nil unsets)
    SCRUBBED_ENV = %w[GEM_HOST_API_KEY RUBYGEMS_API_KEY GITHUB_TOKEN GH_TOKEN]
      .to_h { |name| [name, nil] }.freeze

    DETAIL_LINES = 12

    def initialize(chain:, graph:, workdir:, shell: Shell.new, token: nil,
                   clone_url: nil)
      @chain = chain
      @graph = graph
      @workdir = File.expand_path(workdir)
      @shell = shell
      @token = token
      @clone_url = clone_url || ->(repo) { "https://github.com/#{repo}.git" }
    end

    def call(pins, externals: [])
      recipe = GateRecipe.new(@chain, @graph).build(pins)
      validate_commands!(recipe)
      blocked = awaiting_step(externals)
      return verdict([blocked]) if blocked

      steps = compile(pins, externals)
      steps.concat(suites(recipe)) if all_ok?(steps)
      steps.concat(canary(recipe)) if all_ok?(steps)
      verdict(steps)
    end

    private

    def all_ok?(steps)
      steps.all? { |s| s.status == "ok" }
    end

    def validate_commands!(recipe)
      refuse_publishing!(recipe.canary, "canary")
      recipe.suites.each { |suite| refuse_publishing!(suite.commands, "suite") }
    end

    def refuse_publishing!(commands, kind)
      bad = commands.grep(PUBLISHING)
      return if bad.empty?

      raise Refused, "#{kind} command would publish: #{bad.join('; ')}"
    end

    # the lock cannot be completed while an external need has no final:
    # red without running anything (the gate never validates a prerelease
    # of another chain)
    def awaiting_step(externals)
      awaiting = GateLock.new(@chain, @graph, externals: externals).awaiting
      return if awaiting.empty?

      list = awaiting.map { |f| "#{f.from.join(', ')} -> #{f.gem}" }
      Step.new(name: "lock: externals awaiting release", kind: "compile",
               status: "failed", detail: list.join("\n"), gems: [])
    end

    def compile(pins, externals)
      FileUtils.mkdir_p(lock_dir)
      lock = GateLock.new(@chain, @graph, externals: externals)
      File.write(File.join(lock_dir, "Gemfile"), lock.gemfile(pins))
      steps = []
      [%w[bundle lock], %w[bundle install]].each do |argv|
        steps << run_step(argv, "lock: #{argv.join(' ')}", "compile")
        break unless steps.last.status == "ok"
      end
      steps
    end

    def run_step(argv, name, kind)
      step(name, kind, @shell.run(argv, chdir: lock_dir, env: bundle_env))
    end

    def suites(recipe)
      recipe.suites.flat_map { |suite| gem_suite(suite) }
    end

    def gem_suite(suite)
      dir = File.join(@workdir, "suites", suite.gem)
      cloned = clone(suite.repo, dir, ref: "main", kind: "suite",
                                      gems: [suite.gem])
      return [cloned] unless cloned.status == "ok"

      [cloned] + suite.commands.map do |command|
        result = @shell.run(command, chdir: dir, env: bundle_env)
        step("suite #{suite.gem}: #{command}", "suite", result,
             gems: [suite.gem])
      end
    end

    def canary(recipe)
      return lock_dir_canary(recipe) if recipe.corpora.empty?

      recipe.corpora.flat_map { |corpus| corpus_canary(corpus, recipe.canary) }
    end

    def lock_dir_canary(recipe)
      recipe.canary.map do |command|
        result = @shell.run(command, chdir: lock_dir, env: bundle_env)
        step("canary: #{command}", "canary", result, gems: [])
      end
    end

    def corpus_canary(corpus, commands)
      dir = File.join(@workdir, "corpora", corpus.repo.gsub("/", "__"))
      cloned = clone(corpus.repo, dir, ref: corpus.ref, kind: "corpus",
                                       gems: corpus.gems)
      return [cloned] unless cloned.status == "ok"

      commands.map { |command| corpus_step(corpus, dir, command) }
    end

    def corpus_step(corpus, dir, command)
      env = bundle_env.merge(
        "ANCORA_CORPUS_DOCUMENTS" => corpus.documents.join("\n"),
      )
      result = @shell.run(command, chdir: dir, env: env, timeout: corpus.budget)
      step("corpus #{corpus.repo}: #{command}", "corpus", result,
           gems: corpus.gems)
    end

    def clone(repo, dir, ref:, kind:, gems:)
      FileUtils.rm_rf(dir)
      FileUtils.mkdir_p(File.dirname(dir))
      argv = ["git", "clone", "--depth", "1", "--branch", ref,
              @clone_url.call(repo), dir]
      result = @shell.run(argv, chdir: @workdir, env: git_env)
      step("clone #{repo}@#{ref}", kind, result, gems: gems)
    end

    def verdict(steps)
      failed = steps.reject { |s| s.status == "ok" }
      suspects = failed.flat_map(&:gems).uniq.sort
      Verdict.new(result: failed.empty? ? "green" : "red", steps: steps,
                  suspects: suspects)
    end

    def step(name, kind, result, gems: [])
      status = if result.ok? then "ok"
               elsif result.timed_out then "timeout"
               else "failed"
               end
      Step.new(name: name, kind: kind, status: status,
               detail: tail(result.output), gems: gems)
    end

    def tail(output)
      output.to_s.lines.last(DETAIL_LINES).join.then { |t| redact(t) }
    end

    def redact(text)
      @token ? text.gsub(@token, "***") : text
    end

    def lock_dir
      File.join(@workdir, "lock")
    end

    def bundle_env
      SCRUBBED_ENV.merge("BUNDLE_GEMFILE" => File.join(lock_dir, "Gemfile"))
    end

    # the token travels in the environment, never in argv or the URL
    def git_env
      return SCRUBBED_ENV unless @token

      basic = ["x-access-token:#{@token}"].pack("m0")
      SCRUBBED_ENV.merge(
        "GIT_CONFIG_COUNT" => "1",
        "GIT_CONFIG_KEY_0" => "http.https://github.com/.extraheader",
        "GIT_CONFIG_VALUE_0" => "Authorization: basic #{basic}",
      )
    end
  end
end
