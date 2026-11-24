# frozen_string_literal: true

module Ancora
  # The standing per-gem drift of a fleet, the data behind the weekly
  # report. Read-only over collector data plus, optionally, a tag oracle:
  #
  #   ahead      commits on main since the latest release
  #   behind     main's VERSION is older than the latest release (a
  #              release cut from elsewhere; main must catch up)
  #   tagged     whether the latest release has its v<version> git tag
  #              (nil when no tag oracle was given)
  #
  # Floor violations are the Drift findings (floorless, stale pins,
  # prerelease floors) plus floors no release satisfies yet.
  class FleetDrift
    Row = Struct.new(:gem, :repo, :main_version, :released, :ahead_by,
                     :behind, :tagged, keyword_init: true) do
      def untagged_release?
        tagged == false
      end
    end
    UnpublishedFloor = Struct.new(:from, :to, :constraints, :released,
                                  keyword_init: true)
    Report = Struct.new(:rows, :drift, :unpublished_floors, keyword_init: true)

    # tags: anything answering tagged_version?(repo, version), e.g.
    # Oracle::Github; nil skips the tag check.
    def initialize(graph, chain: nil, tags: nil)
      @graph = graph
      @chain = chain
      @tags = tags
    end

    def report
      drift = Drift.new(@graph, chain: @chain).report
      Report.new(rows: rows, drift: drift,
                 unpublished_floors: unpublished_floors)
    end

    private

    def scope
      @scope ||= @chain ? @chain.inventory(@graph) : @graph.nodes.keys
    end

    def rows
      scope.sort.filter_map { |name| row(@graph.nodes[name]) }
    end

    def row(node)
      return unless node

      Row.new(gem: node.name, repo: node.repo, main_version: node.main_version,
              released: node.released, ahead_by: node.ahead_by.to_i,
              behind: behind?(node), tagged: tagged(node))
    end

    def behind?(node)
      return false unless node.released && node.main_version

      Gem::Version.new(node.main_version) < Gem::Version.new(node.released)
    end

    def tagged(node)
      return nil unless @tags && node.released

      @tags.tagged_version?(node.repo, node.released)
    end

    def unpublished_floors
      @graph.edges.filter_map { |edge| unpublished_floor(edge) }
    end

    def unpublished_floor(edge)
      return unless checked?(edge)

      released = @graph.nodes[edge.to]&.released
      return if released.nil? || satisfied?(edge.constraints, released)

      UnpublishedFloor.new(**edge.to_h, released: released)
    end

    def checked?(edge)
      !edge.constraints.empty? && scope.include?(edge.from)
    end

    def satisfied?(constraints, version)
      requirement = Gem::Requirement.new(*constraints)
      requirement.satisfied_by?(Gem::Version.new(version))
    end
  end
end
