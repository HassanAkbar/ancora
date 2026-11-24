# frozen_string_literal: true

module Ancora
  # Release notes generated from merged pull requests, never hand-written.
  # Input is the PR list since the previous tag (the `gh pr list --state
  # merged --json number,title,author,mergedAt,url` shape); output is
  # markdown. Pure: no network, so the notes are reproducible from the data.
  class ReleaseNotes
    def initialize(pull_requests)
      @pull_requests = pull_requests
    end

    def render(version)
      lines = ["## #{version}", ""]
      if merged.empty?
        lines << "No merged pull requests since the previous release."
      else
        merged.each { |pr| lines << entry(pr) }
      end
      "#{lines.join("\n")}\n"
    end

    private

    # only merged PRs, oldest first, so notes read in landing order
    def merged
      @merged ||= @pull_requests.select { |pr| pr["mergedAt"] }
        .sort_by { |pr| [pr["mergedAt"], pr["number"]] }
    end

    def entry(request)
      author = request.dig("author", "login")
      "- #{request['title']} (##{request['number']}#{" @#{author}" if author})"
    end
  end
end
