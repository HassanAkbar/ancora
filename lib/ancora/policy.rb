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
      %r{uses:\s*metanorma/ci/\.github/workflows/rubygems-release\.yml@\S+}
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
        current = File.read(file)[/VERSION\s*=\s*["']([^"']+)["']/, 1]
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

      text = File.read(path)
      missing = []
      missing << "does not call the reusable rubygems-release" unless
        REUSABLE_RELEASE.match?(text)
      unless text.include?("next_version:")
        missing << "has no next_version input"
      end
      unless text.include?("do-release")
        missing << "ignores the do-release dispatch"
      end
      missing.map { |why| finding(:release_workflow, "release.yml #{why}") }
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

    def ignored?(name)
      path = File.join(@root, ".gitignore")
      File.file?(path) && File.readlines(path, chomp: true)
        .any? { |l| ["/#{name}", name].include?(l.strip) }
    end

    def finding(rule, message)
      Finding.new(rule: rule, message: message)
    end
  end
end
