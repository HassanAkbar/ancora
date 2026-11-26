# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ancora::Graph do
  def network(constraints)
    {
      "lutaml/ea" => { "name" => "ea", "main_version" => "0.6.41",
                       "deps" => [{ "name" => "xmi",
                                    "constraints" => constraints }] },
      "lutaml/xmi" => { "name" => "xmi", "main_version" => "0.7.6",
                        "deps" => [] },
    }
  end

  it "reads a dependency with no constraints as having none" do
    edge = described_class.from_data(network(nil), {}).edges.first
    expect(edge.constraints).to eq []
  end

  it "refuses constraints that are not a list, naming the edge" do
    expect { described_class.from_data(network("~> 0.7"), {}) }
      .to raise_error(ArgumentError, /ea -> xmi.*must be a list/)
  end
end
