# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ancora::ReleaseNotes do
  let(:prs) do
    [
      { "number" => 12, "title" => "Fix table cells",
        "mergedAt" => "2026-11-02T10:00",
        "author" => { "login" => "alice" } },
      { "number" => 9, "title" => "Add figure ids",
        "mergedAt" => "2026-11-01T10:00",
        "author" => { "login" => "bob" } },
      { "number" => 11, "title" => "Closed unmerged", "mergedAt" => nil,
        "author" => { "login" => "eve" } },
    ]
  end

  it "lists merged PRs oldest first and drops unmerged ones" do
    expect(described_class.new(prs).render("1.2.4")).to eq(<<~MD)
      ## 1.2.4

      - Add figure ids (#9 @bob)
      - Fix table cells (#12 @alice)
    MD
  end

  it "says so when nothing merged" do
    expect(described_class.new([]).render("1.2.4"))
      .to include("No merged pull requests")
  end
end
