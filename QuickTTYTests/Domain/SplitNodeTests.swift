import Foundation
import Testing

@testable import QuickTTY

struct SplitNodeTests {
    @Test
    func horizontalSplitReplacesTargetWithOrderedBranch() throws {
        let existingPane = PaneID()
        let newPane = PaneID()
        var root = SplitNode.pane(existingPane)

        let didSplit = root.split(existingPane, axis: .horizontal, newPane: newPane, ratio: 0.4)

        #expect(didSplit)
        guard case .split(_, let axis, let ratio, let first, let second) = root else {
            Issue.record("Expected a split root")
            return
        }
        #expect(axis == .horizontal)
        #expect(ratio == 0.4)
        #expect(first == .pane(existingPane))
        #expect(second == .pane(newPane))
        #expect(root.leaves == [existingPane, newPane])
    }

    @Test
    func verticalSplitCanNestInsideExistingTree() {
        let firstPane = PaneID()
        let secondPane = PaneID()
        let thirdPane = PaneID()
        var root = SplitNode.pane(firstPane)
        let didCreateRoot = root.split(
            firstPane,
            axis: .horizontal,
            newPane: secondPane,
            ratio: 0.4
        )
        let didCreateNestedSplit = root.split(
            secondPane,
            axis: .vertical,
            newPane: thirdPane,
            ratio: 0.6
        )

        #expect(didCreateRoot)
        #expect(didCreateNestedSplit)
        guard
            case .split(_, .horizontal, 0.4, .pane(let actualFirst), let nested) = root,
            case .split(_, .vertical, 0.6, .pane(let actualSecond), .pane(let actualThird)) = nested
        else {
            Issue.record("Expected a nested vertical split")
            return
        }
        #expect(actualFirst == firstPane)
        #expect(actualSecond == secondPane)
        #expect(actualThird == thirdPane)
        #expect(root.leaves == [firstPane, secondPane, thirdPane])
    }

    @Test
    func splitReturnsFalseAndPreservesTreeForUnknownTarget() {
        let pane = PaneID()
        let unknownPane = PaneID()
        var root = SplitNode.pane(pane)
        let original = root

        let didSplit = root.split(
            unknownPane,
            axis: .horizontal,
            newPane: PaneID(),
            ratio: 0.5
        )

        #expect(!didSplit)
        #expect(root == original)
    }

    @Test
    func splitCreationClampsLowAndHighRatios() {
        let lowTarget = PaneID()
        var lowRoot = SplitNode.pane(lowTarget)
        let didCreateLowSplit = lowRoot.split(
            lowTarget,
            axis: .horizontal,
            newPane: PaneID(),
            ratio: -1
        )

        let highTarget = PaneID()
        var highRoot = SplitNode.pane(highTarget)
        let didCreateHighSplit = highRoot.split(
            highTarget,
            axis: .vertical,
            newPane: PaneID(),
            ratio: 2
        )

        #expect(didCreateLowSplit)
        #expect(didCreateHighSplit)
        guard
            case .split(_, _, let lowRatio, _, _) = lowRoot,
            case .split(_, _, let highRatio, _, _) = highRoot
        else {
            Issue.record("Expected split roots")
            return
        }
        #expect(lowRatio == 0.1)
        #expect(highRatio == 0.9)
    }

    @Test
    func splitCreationNormalizesNonFiniteRatiosAndPreservesExistingTree() {
        let ratios = [Double.nan, Double.infinity, -Double.infinity]

        for ratio in ratios {
            let outerID = UUID()
            let targetPane = PaneID()
            let existingPane = PaneID()
            let newPane = PaneID()
            var root = SplitNode.split(
                id: outerID,
                axis: .vertical,
                ratio: 0.4,
                first: .pane(targetPane),
                second: .pane(existingPane)
            )

            let didSplit = root.split(
                targetPane,
                axis: .horizontal,
                newPane: newPane,
                ratio: ratio
            )

            #expect(didSplit)
            guard
                case .split(
                    let actualOuterID,
                    .vertical,
                    0.4,
                    let nested,
                    .pane(let actualExistingPane)
                ) = root,
                case .split(
                    _,
                    .horizontal,
                    let actualRatio,
                    .pane(let actualTargetPane),
                    .pane(let actualNewPane)
                ) = nested
            else {
                Issue.record("Expected the existing tree with a nested split")
                continue
            }
            #expect(actualOuterID == outerID)
            #expect(actualRatio == 0.5)
            #expect(actualTargetPane == targetPane)
            #expect(actualExistingPane == existingPane)
            #expect(actualNewPane == newPane)
        }
    }

    @Test
    func containsReportsWhetherPaneIsPresent() {
        let firstPane = PaneID()
        let secondPane = PaneID()
        let unknownPane = PaneID()
        var root = SplitNode.pane(firstPane)
        let didSplit = root.split(
            firstPane,
            axis: .horizontal,
            newPane: secondPane,
            ratio: 0.5
        )

        #expect(didSplit)
        #expect(root.contains(firstPane))
        #expect(root.contains(secondPane))
        #expect(!root.contains(unknownPane))
    }

    @Test
    func removingLeafCollapsesItsParent() throws {
        let left = PaneID()
        let right = PaneID()
        var root = SplitNode.pane(left)
        let didSplit = root.split(left, axis: .horizontal, newPane: right, ratio: 0.5)

        #expect(didSplit)
        root = try #require(root.removing(right))

        #expect(root == .pane(left))
    }

    @Test
    func removingNestedLeafCollapsesOnlyItsParent() throws {
        let firstPane = PaneID()
        let secondPane = PaneID()
        let thirdPane = PaneID()
        let outerID = UUID()
        let innerID = UUID()
        let root = SplitNode.split(
            id: outerID,
            axis: .horizontal,
            ratio: 0.4,
            first: .pane(firstPane),
            second: .split(
                id: innerID,
                axis: .vertical,
                ratio: 0.6,
                first: .pane(secondPane),
                second: .pane(thirdPane)
            )
        )

        let updated = try #require(root.removing(secondPane))

        #expect(
            updated
                == .split(
                    id: outerID,
                    axis: .horizontal,
                    ratio: 0.4,
                    first: .pane(firstPane),
                    second: .pane(thirdPane)
                ))
    }

    @Test
    func removingRootPaneReturnsNil() {
        let pane = PaneID()

        #expect(SplitNode.pane(pane).removing(pane) == nil)
    }

    @Test
    func removingUnknownPanePreservesTree() {
        let root = SplitNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.3,
            first: .pane(PaneID()),
            second: .pane(PaneID())
        )

        #expect(root.removing(PaneID()) == root)
    }

    @Test
    func leavesKeepDepthFirstOrderThroughNestedOperations() throws {
        let firstPane = PaneID()
        let secondPane = PaneID()
        let thirdPane = PaneID()
        let fourthPane = PaneID()
        var root = SplitNode.pane(firstPane)
        let didCreateRoot = root.split(
            firstPane,
            axis: .horizontal,
            newPane: secondPane,
            ratio: 0.5
        )
        let didSplitFirstPane = root.split(
            firstPane,
            axis: .vertical,
            newPane: thirdPane,
            ratio: 0.5
        )
        let didSplitSecondPane = root.split(
            secondPane,
            axis: .vertical,
            newPane: fourthPane,
            ratio: 0.5
        )

        #expect(didCreateRoot)
        #expect(didSplitFirstPane)
        #expect(didSplitSecondPane)
        #expect(root.leaves == [firstPane, thirdPane, secondPane, fourthPane])

        root = try #require(root.removing(thirdPane))
        #expect(root.leaves == [firstPane, secondPane, fourthPane])
    }

    @Test
    func updatingRatioChangesOnlyMatchingSplitAndClampsHighValue() {
        let outerID = UUID()
        let innerID = UUID()
        let firstPane = PaneID()
        let secondPane = PaneID()
        let thirdPane = PaneID()
        let root = SplitNode.split(
            id: outerID,
            axis: .horizontal,
            ratio: 0.4,
            first: .pane(firstPane),
            second: .split(
                id: innerID,
                axis: .vertical,
                ratio: 0.6,
                first: .pane(secondPane),
                second: .pane(thirdPane)
            )
        )

        let updated = root.updatingRatio(splitID: innerID, ratio: 2)

        #expect(
            updated
                == .split(
                    id: outerID,
                    axis: .horizontal,
                    ratio: 0.4,
                    first: .pane(firstPane),
                    second: .split(
                        id: innerID,
                        axis: .vertical,
                        ratio: 0.9,
                        first: .pane(secondPane),
                        second: .pane(thirdPane)
                    )
                ))
    }

    @Test
    func updatingRatioClampsLowValue() {
        let splitID = UUID()
        let firstPane = PaneID()
        let secondPane = PaneID()
        let root = SplitNode.split(
            id: splitID,
            axis: .horizontal,
            ratio: 0.5,
            first: .pane(firstPane),
            second: .pane(secondPane)
        )

        guard
            case .split(let updatedID, let axis, let ratio, let first, let second) =
                root.updatingRatio(splitID: splitID, ratio: -1)
        else {
            Issue.record("Expected a split root")
            return
        }
        #expect(updatedID == splitID)
        #expect(axis == .horizontal)
        #expect(ratio == 0.1)
        #expect(first == .pane(firstPane))
        #expect(second == .pane(secondPane))
    }

    @Test
    func updatingRatioNormalizesNonFiniteValuesAndPreservesTreeIDs() {
        let ratios = [Double.nan, Double.infinity, -Double.infinity]

        for ratio in ratios {
            let outerID = UUID()
            let innerID = UUID()
            let firstPane = PaneID()
            let secondPane = PaneID()
            let thirdPane = PaneID()
            let root = SplitNode.split(
                id: outerID,
                axis: .horizontal,
                ratio: 0.4,
                first: .pane(firstPane),
                second: .split(
                    id: innerID,
                    axis: .vertical,
                    ratio: 0.6,
                    first: .pane(secondPane),
                    second: .pane(thirdPane)
                )
            )

            let updated = root.updatingRatio(splitID: innerID, ratio: ratio)

            #expect(
                updated
                    == .split(
                        id: outerID,
                        axis: .horizontal,
                        ratio: 0.4,
                        first: .pane(firstPane),
                        second: .split(
                            id: innerID,
                            axis: .vertical,
                            ratio: 0.5,
                            first: .pane(secondPane),
                            second: .pane(thirdPane)
                        )
                    ))
        }
    }

    @Test
    func updatingUnknownSplitPreservesTree() {
        let root = SplitNode.split(
            id: UUID(),
            axis: .vertical,
            ratio: 0.5,
            first: .pane(PaneID()),
            second: .pane(PaneID())
        )

        #expect(root.updatingRatio(splitID: UUID(), ratio: 0.8) == root)
    }

    @Test(arguments: [("2.0", 0.9), ("-1.0", 0.1)])
    func decodingClampsOutOfRangeSplitRatio(ratioJSON: String, expectedRatio: Double) throws {
        let splitID = UUID()
        let firstPane = PaneID()
        let secondPane = PaneID()
        let data = splitJSON(
            splitID: splitID,
            ratioJSON: ratioJSON,
            firstPane: firstPane,
            secondPane: secondPane
        )

        let decoded = try JSONDecoder().decode(SplitNode.self, from: data)

        #expect(
            decoded
                == .split(
                    id: splitID,
                    axis: .horizontal,
                    ratio: expectedRatio,
                    first: .pane(firstPane),
                    second: .pane(secondPane)
                ))
    }

    @Test
    func decodingConfiguredNonConformingNaNNormalizesSplitRatio() throws {
        let splitID = UUID()
        let firstPane = PaneID()
        let secondPane = PaneID()
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "+Infinity",
            negativeInfinity: "-Infinity",
            nan: "NaN"
        )
        let data = splitJSON(
            splitID: splitID,
            ratioJSON: "\"NaN\"",
            firstPane: firstPane,
            secondPane: secondPane
        )

        let decoded = try decoder.decode(SplitNode.self, from: data)

        #expect(
            decoded
                == .split(
                    id: splitID,
                    axis: .horizontal,
                    ratio: 0.5,
                    first: .pane(firstPane),
                    second: .pane(secondPane)
                ))
    }

    @Test
    func encodingNormalizesDirectlyConstructedMalformedRatioAtCodableBoundary() throws {
        let splitID = UUID()
        let firstPane = PaneID()
        let secondPane = PaneID()
        let malformed = SplitNode.split(
            id: splitID,
            axis: .vertical,
            ratio: .nan,
            first: .pane(firstPane),
            second: .pane(secondPane)
        )

        let encoded = try JSONEncoder().encode(malformed)
        let decoded = try JSONDecoder().decode(SplitNode.self, from: encoded)

        #expect(
            decoded
                == .split(
                    id: splitID,
                    axis: .vertical,
                    ratio: 0.5,
                    first: .pane(firstPane),
                    second: .pane(secondPane)
                ))
    }

    @Test
    func codableRoundTripPreservesNestedTree() throws {
        let root = SplitNode.split(
            id: UUID(),
            axis: .horizontal,
            ratio: 0.35,
            first: .pane(PaneID()),
            second: .split(
                id: UUID(),
                axis: .vertical,
                ratio: 0.65,
                first: .pane(PaneID()),
                second: .pane(PaneID())
            )
        )

        let encoded = try JSONEncoder().encode(root)
        let decoded = try JSONDecoder().decode(SplitNode.self, from: encoded)

        #expect(decoded == root)
    }

    private func splitJSON(
        splitID: UUID,
        ratioJSON: String,
        firstPane: PaneID,
        secondPane: PaneID
    ) -> Data {
        Data(
            """
            {
              "kind": "split",
              "id": "\(splitID.uuidString)",
              "axis": "horizontal",
              "ratio": \(ratioJSON),
              "first": {
                "kind": "pane",
                "paneID": { "rawValue": "\(firstPane.rawValue.uuidString)" }
              },
              "second": {
                "kind": "pane",
                "paneID": { "rawValue": "\(secondPane.rawValue.uuidString)" }
              }
            }
            """.utf8
        )
    }

    @Test
    func splitAxisRawValuesAreStable() {
        #expect(SplitAxis.horizontal.rawValue == "horizontal")
        #expect(SplitAxis.vertical.rawValue == "vertical")
        #expect(SplitAxis(rawValue: "horizontal") == .horizontal)
        #expect(SplitAxis(rawValue: "vertical") == .vertical)
    }
}
