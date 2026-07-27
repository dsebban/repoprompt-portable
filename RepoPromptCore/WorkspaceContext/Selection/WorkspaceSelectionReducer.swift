import Foundation

package struct WorkspaceSliceEntry: Equatable, Sendable {
	package let path: String
	package let ranges: [LineRange]

	package init(path: String, ranges: [LineRange]) {
		self.path = path
		self.ranges = ranges
	}
}

package enum WorkspaceSelectionMutation: Equatable, Sendable {
	case replaceWithFullFiles([String])
	case addFullFiles([String])
	case replaceWithSlices([WorkspaceSliceEntry])
	case setSlices([WorkspaceSliceEntry])
	case addSlices([WorkspaceSliceEntry])
	case subtractSlices([WorkspaceSliceEntry])
	case replaceWithManualCodemaps([String])
	case addManualCodemaps([String])
	case removeManualCodemaps([String])
	case promoteToFull([String])
	case demoteToManualCodemap([String])
	case removeFiles([String])
	case clear
	case setAutomaticCodemapsEnabled(Bool)
}

package enum WorkspaceSelectionLimitViolation: Error, Equatable, Sendable {
	case tooManyPaths
	case sliceRangeCountOutOfRange
	case totalSliceRangesExceeded
	case invalidSliceDescription
}

package enum WorkspaceSelectionReducer {
	package static let maximumSelectionEntries = 1_024
	package static let maximumRangesPerFile = 256
	package static let maximumTotalRanges = 4_096

	package static func apply(
		_ mutation: WorkspaceSelectionMutation,
		to selection: inout WorkspaceSelectionSnapshot,
		codemapAutoEnabledOverride: Bool? = nil
	) throws {
		canonicalize(&selection)

		switch mutation {
		case .replaceWithFullFiles(let paths):
			selection.selectedPaths = orderedUnique(paths)
			selection.slices = [:]
			selection.manualCodemapPaths = []
		case .addFullFiles(let paths):
			appendUnique(paths, to: &selection.selectedPaths)
			let added = Set(paths)
			selection.manualCodemapPaths.removeAll { added.contains($0) }
			for path in added { selection.slices.removeValue(forKey: path) }
		case .replaceWithSlices(let entries):
			selection.selectedPaths = []
			selection.slices = [:]
			selection.manualCodemapPaths = []
			try applySlices(entries, to: &selection, coalescing: false)
		case .setSlices(let entries):
			try applySlices(entries, to: &selection, coalescing: false)
		case .addSlices(let entries):
			try applySlices(entries, to: &selection, coalescing: true)
		case .subtractSlices(let entries):
			for entry in entries {
				guard let existing = selection.slices[entry.path] else { continue }
				let removal = SliceRangeMath.normalize(entry.ranges)
				guard !removal.isEmpty else { continue }
				let remaining = SliceRangeMath.subtract(existing, removing: removal)
				if remaining.isEmpty {
					selection.slices.removeValue(forKey: entry.path)
					selection.selectedPaths.removeAll { $0 == entry.path }
				} else {
					selection.slices[entry.path] = remaining
				}
			}
		case .replaceWithManualCodemaps(let paths):
			selection.selectedPaths = []
			selection.slices = [:]
			selection.manualCodemapPaths = orderedUnique(paths)
			selection.codemapAutoEnabled = false
		case .addManualCodemaps(let paths), .demoteToManualCodemap(let paths):
			let manual = Set(paths)
			selection.selectedPaths.removeAll { manual.contains($0) }
			for path in manual { selection.slices.removeValue(forKey: path) }
			appendUnique(paths, to: &selection.manualCodemapPaths)
			selection.codemapAutoEnabled = false
		case .removeManualCodemaps(let paths):
			let removed = Set(paths)
			selection.manualCodemapPaths.removeAll { removed.contains($0) }
		case .promoteToFull(let paths):
			appendUnique(paths, to: &selection.selectedPaths)
			let promoted = Set(paths)
			selection.manualCodemapPaths.removeAll { promoted.contains($0) }
			for path in promoted { selection.slices.removeValue(forKey: path) }
		case .removeFiles(let paths):
			let removed = Set(paths)
			selection.selectedPaths.removeAll { removed.contains($0) }
			selection.manualCodemapPaths.removeAll { removed.contains($0) }
			for path in removed { selection.slices.removeValue(forKey: path) }
		case .clear:
			selection = WorkspaceSelectionSnapshot()
		case .setAutomaticCodemapsEnabled(let enabled):
			selection.codemapAutoEnabled = enabled
		}

		if let codemapAutoEnabledOverride {
			selection.codemapAutoEnabled = codemapAutoEnabledOverride
		}
		canonicalize(&selection)
		try validateLimits(selection)
	}

	package static func validateLimits(_ selection: WorkspaceSelectionSnapshot) throws {
		let paths = Set(selection.selectedPaths + selection.manualCodemapPaths + Array(selection.slices.keys))
		guard paths.count <= maximumSelectionEntries else {
			throw WorkspaceSelectionLimitViolation.tooManyPaths
		}
		guard selection.slices.values.allSatisfy({ !$0.isEmpty && $0.count <= maximumRangesPerFile }) else {
			throw WorkspaceSelectionLimitViolation.sliceRangeCountOutOfRange
		}
		guard selection.slices.values.reduce(0, { $0 + $1.count }) <= maximumTotalRanges else {
			throw WorkspaceSelectionLimitViolation.totalSliceRangesExceeded
		}
		guard selection.slices.values.joined().allSatisfy({ range in
			guard let description = range.description else { return true }
			return !description.contains("\0") && description.utf8.count <= 1_024
		}) else {
			throw WorkspaceSelectionLimitViolation.invalidSliceDescription
		}
	}

	private static func applySlices(
		_ entries: [WorkspaceSliceEntry],
		to selection: inout WorkspaceSelectionSnapshot,
		coalescing: Bool
	) throws {
		var grouped: [String: [LineRange]] = [:]
		var orderedPaths: [String] = []
		for entry in entries {
			if grouped[entry.path] == nil { orderedPaths.append(entry.path) }
			grouped[entry.path, default: []].append(contentsOf: entry.ranges)
		}
		for path in orderedPaths {
			let ranges = SliceRangeMath.normalize(grouped[path] ?? [])
			guard !ranges.isEmpty else { throw WorkspaceSelectionLimitViolation.sliceRangeCountOutOfRange }
			selection.slices[path] = coalescing
				? SliceRangeMath.coalesce(selection.slices[path] ?? [], ranges)
				: ranges
		}
		appendUnique(orderedPaths, to: &selection.selectedPaths)
		let sliced = Set(orderedPaths)
		selection.manualCodemapPaths.removeAll { sliced.contains($0) }
	}

	private static func canonicalize(_ selection: inout WorkspaceSelectionSnapshot) {
		selection.selectedPaths = orderedUnique(selection.selectedPaths)
		selection.manualCodemapPaths = orderedUnique(selection.manualCodemapPaths)

		let selected = Set(selection.selectedPaths)
		var invalidSlicePaths = Set<String>()
		var slices: [String: [LineRange]] = [:]
		for (path, ranges) in selection.slices where selected.contains(path) {
			let normalized = SliceRangeMath.normalize(ranges)
			if normalized.isEmpty || normalized.contains(where: { $0.start < 1 }) {
				invalidSlicePaths.insert(path)
			} else {
				slices[path] = normalized
			}
		}
		selection.selectedPaths.removeAll { invalidSlicePaths.contains($0) }
		selection.slices = slices

		let remainingSelected = Set(selection.selectedPaths)
		selection.manualCodemapPaths.removeAll { remainingSelected.contains($0) }
	}

	private static func orderedUnique(_ paths: [String]) -> [String] {
		var seen = Set<String>()
		return paths.filter { seen.insert($0).inserted }
	}

	private static func appendUnique<S: Sequence>(_ paths: S, to target: inout [String]) where S.Element == String {
		var seen = Set(target)
		for path in paths where seen.insert(path).inserted {
			target.append(path)
		}
	}
}
