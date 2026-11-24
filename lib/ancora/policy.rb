# frozen_string_literal: true

module Ancora
  # The owner's standing release rules as machine checks over one gem
  # checkout. Read-only: it inspects files and `git ls-files`, nothing is
  # written, tagged or released. Humans still authorize the release; this
  # only reports whether the repo is fit to be released.
  #
  #   version_behind_next      lib/**/version.rb sits strictly BEHIND the
  #                            requested next_version (the release workflow
  #                            performs the bump; a branch never pre-bumps)
  #   release_workflow         .github/workflows/release.yml registers the
  #                            reusable metanorma/ci rubygems-release workflow
  #                            with a next_version input and do-release dispatch
  #   lockfile_uncommitted     Gemfile.lock is git-ignored and not tracked
  class Policy
    REUSABLE_RELEASE =
      %r{\Ametanorma/ci/\.github/workflows/rubygems-release\.yml@\S+\z}
    VERSION_LINE = /\A\s*VERSION\s*=\s*["']([^"']+)["']/
    Finding = Struct.new(:rule, :message, keyword_init: true)

    RULES = %i[version_behind_next release_workflow lockfile_uncommitted].freeze

    def initialize(root, next_version: nil)
      @root = root
      @next_version = next_version
    end

    # Findings for every violated rule; empty means the repo conforms.
    # Without a next_version the version rule is skipped (nothing to compare).
    def check
      RULES.flat_map { |rule| send(rule) }
    end

    private

    def version_behind_next
      return [] unless @next_version

      files = Dir.glob(File.join(@root, "lib", "**", "version.rb"))
      if files.empty?
        return [finding(:version_behind_next,
                        "no lib/**/version.rb found")]
      end

      files.filter_map do |file|
        current = version_literal(File.read(file))
        relative = file.delete_prefix("#{@root}/")
        if current.nil?
          finding(:version_behind_next, "#{relative}: no VERSION literal")
        elsif Gem::Version.new(current) >= Gem::Version.new(@next_version)
          finding(:version_behind_next,
                  "#{relative}: #{current} is not behind " \
                  "next_version #{@next_version}")
        end
      end
    end

    def release_workflow
      path = File.join(@root, ".github", "workflows", "release.yml")
      unless File.file?(path)
        return [finding(:release_workflow,
                        "missing .github/workflows/release.yml")]
      end

      workflow = load_workflow(path)
      problems = workflow ? workflow_problems(workflow) : ["is not valid YAML"]
      problems.map { |why| finding(:release_workflow, "release.yml #{why}") }
    end

    def workflow_problems(workflow)
      {
        "does not call the reusable rubygems-release" =>
          reusable_job?(workflow),
        "has no next_version input" => next_version_input?(workflow),
        "ignores the do-release dispatch" => do_release?(workflow),
      }.reject { |_why, ok| ok }.keys
    end

    def lockfile_uncommitted
      [
        (tracked?("Gemfile.lock") ? "Gemfile.lock is tracked by git" : nil),
        (ignored?("Gemfile.lock") ? nil : "Gemfile.lock is not in .gitignore"),
      ].compact.map { |why| finding(:lockfile_uncommitted, why) }
    end

    def tracked?(name)
      out, status = Open3.capture2("git", "ls-files", "--", name, chdir: @root,
                                                                  err: File::NULL)
      status.success? && !out.strip.empty?
    end

    # Ask git itself, so negation, wildcards and nested ignore files agree
    # with what `git add` would do.
    def ignored?(name)
      _out, status = Open3.capture2("git", "check-ignore", "-q", "--no-index",
                                    "--", name, chdir: @root, err: File::NULL)
      status.success?
    end

    # First real `VERSION = "x"` assignment; comment lines are skipped and
    # no repo code is executed.
    def version_literal(text)
      text.each_line do |line|
        next if line.lstrip.start_with?("#")

        match = VERSION_LINE.match(line)
        return match[1] if match
      end
      nil
    end

    def load_workflow(path)
      data = YAML.safe_load_file(path)
      data.is_a?(Hash) ? data : nil
    rescue Psych::Exception
      nil
    end

    # YAML 1.1 reads the bare key `on` as boolean true.
    def triggers(workflow)
      on = workflow.fetch("on") { workflow[true] }
      on.is_a?(Hash) ? on : {}
    end

    def next_version_input?(workflow)
      dispatch = triggers(workflow)["workflow_dispatch"]
      inputs = dispatch.is_a?(Hash) ? dispatch["inputs"] : nil
      inputs.is_a?(Hash) && inputs.key?("next_version")
    end

    def do_release?(workflow)
      dispatch = triggers(workflow)["repository_dispatch"]
      types = dispatch.is_a?(Hash) ? Array(dispatch["types"]) : []
      types.include?("do-release")
    end

    def reusable_job?(workflow)
      jobs = workflow["jobs"]
      jobs.is_a?(Hash) && jobs.values.any? do |job|
        job.is_a?(Hash) && REUSABLE_RELEASE.match?(job["uses"].to_s)
      end
    end

    def finding(rule, message)
      Finding.new(rule: rule, message: message)
    end
  end
end
