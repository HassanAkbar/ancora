# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "open3"

RSpec.describe Ancora::Policy do
  let(:release_yml) do
    <<~YML
      on:
        workflow_dispatch:
          inputs:
            next_version:
              required: true
        repository_dispatch:
          types: [ do-release ]
      jobs:
        release:
          uses: metanorma/ci/.github/workflows/rubygems-release.yml@main
    YML
  end

  def write(root, path, text)
    full = File.join(root, path)
    FileUtils.mkdir_p(File.dirname(full))
    File.write(full, text)
  end

  # a conforming gem checkout; the block may break one rule
  def checkout
    Dir.mktmpdir do |root|
      Open3.capture2e("git", "init", "-q", chdir: root)
      write(root, "lib/foo/version.rb", "VERSION = \"1.2.3\"\n")
      write(root, ".github/workflows/release.yml", release_yml)
      write(root, ".gitignore", "/Gemfile.lock\ncoverage/\n")
      yield root
    end
  end

  def rules(root, **opts)
    described_class.new(root, **opts).check.map(&:rule)
  end

  it "passes a conforming checkout" do
    checkout { |root| expect(rules(root, next_version: "1.2.4")).to eq([]) }
  end

  it "flags a version.rb already at or ahead of next_version" do
    checkout do |root|
      expect(rules(root, next_version: "1.2.3")).to eq([:version_behind_next])
      expect(rules(root, next_version: "1.2.0")).to eq([:version_behind_next])
    end
  end

  it "compares versions numerically, not as strings" do
    checkout { |root| expect(rules(root, next_version: "1.10.0")).to eq([]) }
  end

  it "skips the version rule without a next_version" do
    checkout do |root|
      write(root, "lib/foo/version.rb", "VERSION = \"9.9.9\"\n")
      expect(rules(root)).to eq([])
    end
  end

  it "flags a missing release workflow" do
    checkout do |root|
      File.delete(File.join(root, ".github/workflows/release.yml"))
      expect(rules(root)).to eq([:release_workflow])
    end
  end

  it "flags a release workflow that is not the reusable one" do
    checkout do |root|
      write(root, ".github/workflows/release.yml", "on: push\njobs: {}\n")
      messages = described_class.new(root).check.map(&:message)
      expect(messages.size).to eq(3)
    end
  end

  it "flags a Gemfile.lock that is not ignored" do
    checkout do |root|
      write(root, ".gitignore", "coverage/\n")
      expect(rules(root)).to eq([:lockfile_uncommitted])
    end
  end

  it "flags a Gemfile.lock tracked by git" do
    checkout do |root|
      write(root, "Gemfile.lock", "GEM\n")
      Open3.capture2e("git", "add", "-f", "Gemfile.lock", chdir: root)
      expect(described_class.new(root).check.map(&:message))
        .to include("Gemfile.lock is tracked by git")
    end
  end
end
