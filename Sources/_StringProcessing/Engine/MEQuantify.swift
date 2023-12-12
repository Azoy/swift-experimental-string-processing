private typealias ASCIIBitset = DSLTree.CustomCharacterClass.AsciiBitset

extension Processor {
  private func maybeASCIIBitset(
    _ payload: QuantifyPayload
  ) -> ASCIIBitset? {
    guard payload.type == .asciiBitset else { return nil }
    return registers[payload.bitset]
  }

  internal mutating func runQuantify(_ payload: QuantifyPayload) -> Bool {
    let asciiBitset = maybeASCIIBitset(payload)

    // TODO: Refactor below called functions to be non-mutating.
    // They might need to communicate save-point info upwards in addition to
    // a new (optional) currentPosition. Then, we can assert in testing that the
    // specialized functions produce the same answer as `runGeneralQuantify`.
    switch (payload.quantKind, payload.minTrips, payload.maxExtraTrips) {
    case (.reluctant, _, _):
      assertionFailure(".reluctant is not supported by .quantify")
      // TODO: this was pre-refactoring behavior, should we fatal error
      //       instead?
      return false 
    case (.eager, 0, nil):
      let (next, savePointRange) = input.runEagerZeroOrMoreQuantify(
        payload,
        asciiBitset: asciiBitset,
        at: currentPosition,
        limitedBy: end)
      assert((next, savePointRange) == input.runGeneralQuantify(
        payload,
        asciiBitset: asciiBitset,
        at: currentPosition,
        limitedBy: end)!)
      if let savePointRange {
        savePoints.append(makeQuantifiedSavePoint(
          savePointRange, isScalarSemantics: payload.isScalarSemantics))
      }
      currentPosition = next
      return true
    case (.eager, 1, nil):
      guard let (next, savePointRange) = input.runEagerOneOrMoreQuantify(
        payload,
        asciiBitset: asciiBitset,
        at: currentPosition,
        limitedBy: end
      ) else {
        assert(nil == input.runGeneralQuantify(
          payload,
          asciiBitset: asciiBitset,
          at: currentPosition,
          limitedBy: end))
        signalFailure()
        return false
      }
      assert((next, savePointRange) == input.runGeneralQuantify(
        payload,
        asciiBitset: asciiBitset,
        at: currentPosition,
        limitedBy: end)!)
      if let savePointRange {
        savePoints.append(makeQuantifiedSavePoint(
          savePointRange, isScalarSemantics: payload.isScalarSemantics))
      }
      currentPosition = next
      return true
    case (.eager, _, nil):
      guard let (next, savePointRange) = input.runEagerNOrMoreQuantify(
        payload,
        asciiBitset: asciiBitset,
        at: currentPosition,
        limitedBy: end
      ) else {
        assert(nil == input.runGeneralQuantify(
          payload,
          asciiBitset: asciiBitset,
          at: currentPosition,
          limitedBy: end))
        signalFailure()
        return false
      }
      assert((next, savePointRange) == input.runGeneralQuantify(
        payload,
        asciiBitset: asciiBitset,
        at: currentPosition,
        limitedBy: end)!)
      if let savePointRange {
        savePoints.append(makeQuantifiedSavePoint(
          savePointRange, isScalarSemantics: payload.isScalarSemantics))
      }
      currentPosition = next
      return true
    case (_, 0, 1):
      // FIXME: Is this correct for lazy zero-or-one?
      let (next, save) = input.runZeroOrOneQuantify(
        payload,
        asciiBitset: asciiBitset,
        at: currentPosition,
        limitedBy: end)
      // Also, we should assert same answer as runGeneralQuantify...
      if save {
        savePoints.append(makeSavePoint(resumingAt: currentPC+1))
      }
      currentPosition = next
      return true
    default:
      guard let (next, savePointRange) = input.runGeneralQuantify(
        payload,
        asciiBitset: asciiBitset,
        at: currentPosition,
        limitedBy: end
      ) else {
        signalFailure()
        return false
      }
      if let savePointRange {
        savePoints.append(makeQuantifiedSavePoint(
          savePointRange, isScalarSemantics: payload.isScalarSemantics))
      }
      currentPosition = next

      return true
    }
  }
}

extension String {
  fileprivate func doQuantifyMatch(
    _ payload: QuantifyPayload,
    asciiBitset: ASCIIBitset?, // Necessary ugliness...
    at currentPosition: Index,
    limitedBy end: Index
  ) -> Index? {
    let isScalarSemantics = payload.isScalarSemantics

    switch payload.type {
    case .asciiBitset:
      assert(asciiBitset != nil, "Invariant: needs to be passed in")
      return matchASCIIBitset(
        asciiBitset!,
        at: currentPosition,
        limitedBy: end,
        isScalarSemantics: isScalarSemantics)
    case .asciiChar:
      return matchScalar(
        UnicodeScalar.init(_value: UInt32(payload.asciiChar)),
        at: currentPosition,
        limitedBy: end,
        boundaryCheck: !isScalarSemantics,
        isCaseInsensitive: false)
    case .builtin:
      // We only emit .quantify if it consumes a single character
      return matchBuiltinCC(
        payload.builtin,
        at: currentPosition,
        limitedBy: end,
        isInverted: payload.builtinIsInverted,
        isStrictASCII: payload.builtinIsStrict,
        isScalarSemantics: isScalarSemantics)
    case .any:
      return matchRegexDot(
        at: currentPosition,
        limitedBy: end,
        anyMatchesNewline: payload.anyMatchesNewline,
        isScalarSemantics: isScalarSemantics)
    }
  }

  /// Generic quantify instruction interpreter
  /// - Handles .eager and .posessive
  /// - Handles arbitrary minTrips and maxExtraTrips
  fileprivate func runGeneralQuantify(
    _ payload: QuantifyPayload,
    asciiBitset: ASCIIBitset?,
    at currentPosition: Index,
    limitedBy end: Index
  ) -> (
    nextPosition: Index,
    savePointRange: Range<Index>?
  )? {
    assert(payload.quantKind != .reluctant)

    var trips = 0
    var maxExtraTrips = payload.maxExtraTrips
    var currentPosition = currentPosition

    while trips < payload.minTrips {
      guard let next = doQuantifyMatch(
        payload,
        asciiBitset: asciiBitset,
        at: currentPosition,
        limitedBy: end
      ) else {
        return nil
      }
      currentPosition = next
      trips += 1
    }

    if maxExtraTrips == 0 {
      // We're done
      return (currentPosition, nil)
    }

    guard let next = doQuantifyMatch(
      payload,
      asciiBitset: asciiBitset,
      at: currentPosition,
      limitedBy: end
    ) else {
      return (currentPosition, nil)
    }
    maxExtraTrips = maxExtraTrips.map { $0 - 1 }

    // Remember the range of valid positions in case we can create a quantified
    // save point
    let rangeStart = currentPosition
    var rangeEnd = currentPosition
    currentPosition = next

    while true {
      if maxExtraTrips == 0 { break }

      guard let next = doQuantifyMatch(
        payload,
        asciiBitset: asciiBitset,
        at: currentPosition,
        limitedBy: end
      ) else {
        break
      }
      maxExtraTrips = maxExtraTrips.map({$0 - 1})
      rangeEnd = currentPosition
      currentPosition = next
    }

    if payload.quantKind == .eager {
      return (currentPosition, rangeStart..<rangeEnd)
    } else {
      // No backtracking permitted after a successful advance
      assert(payload.quantKind == .possessive)
    }
    return (currentPosition, nil)
  }

  /// Specialized quantify instruction interpreter for `*`, always succeeds
  fileprivate func runEagerZeroOrMoreQuantify(
    _ payload: QuantifyPayload,
    asciiBitset: ASCIIBitset?, // Necessary ugliness...
    at currentPosition: Index,
    limitedBy end: Index
  ) -> (Index, savePointRange: Range<Index>?) {
    assert(payload.quantKind == .eager
           && payload.minTrips == 0
           && payload.maxExtraTrips == nil)
    guard let res = _runEagerNOrMoreQuantify(
      payload,
      minTrips: 0,
      asciiBitset: asciiBitset,
      at: currentPosition,
      limitedBy: end
    ) else {
      fatalError("Unreachable: zero-or-more always succeeds")
    }

    return res
  }

  /// Specialized n-or-more eager quantification interpreter
  ///
  /// NOTE: inline always makes a huge perf difference for zero-or-more case
  @inline(__always)
  fileprivate func _runEagerNOrMoreQuantify(
    _ payload: QuantifyPayload,
    minTrips: UInt64,
    asciiBitset: ASCIIBitset?, // Necessary ugliness...
    at currentPosition: Index,
    limitedBy end: Index
  ) -> (Index, savePointRange: Range<Index>?)? {
    assert(payload.quantKind == .eager)
    assert(payload.maxExtraTrips == nil)
    assert(minTrips == payload.minTrips)

    // Create a quantified save point for every part of the input matched up
    // to the final position.
    var currentPosition = currentPosition
    let isScalarSemantics = payload.isScalarSemantics
    var rangeStart = currentPosition
    var rangeEnd = currentPosition

    var numMatches = 0

    switch payload.type {
    case .asciiBitset:
      while true {
        assert(asciiBitset != nil, "Invariant: needs to be passed in")
        guard let next = matchASCIIBitset(
          asciiBitset!,
          at: currentPosition,
          limitedBy: end,
          isScalarSemantics: isScalarSemantics)
        else {
          break
        }
        numMatches += 1
        if numMatches == minTrips {
          rangeStart = next
        }
        rangeEnd = currentPosition
        currentPosition = next
        assert(currentPosition > rangeEnd)
      }
    case .asciiChar:
      let asciiScalar = UnicodeScalar.init(_value: UInt32(payload.asciiChar))
      while true {
        guard let next = matchScalar(
          asciiScalar,
          at: currentPosition,
          limitedBy: end,
          boundaryCheck: !isScalarSemantics,
          isCaseInsensitive: false)
        else {
          break
        }
        numMatches += 1
        if numMatches == minTrips {
          rangeStart = next
        }
        rangeEnd = currentPosition
        currentPosition = next
        assert(currentPosition > rangeEnd)
      }
    case .builtin:
      let builtin = payload.builtin
      let isInverted = payload.builtinIsInverted
      let isStrictASCII = payload.builtinIsStrict
      while true {
        guard let next = matchBuiltinCC(
          builtin,
          at: currentPosition,
          limitedBy: end,
          isInverted: isInverted,
          isStrictASCII: isStrictASCII,
          isScalarSemantics: isScalarSemantics)
        else {
          break
        }
        numMatches += 1
        if numMatches == minTrips {
          rangeStart = next
        }
        rangeEnd = currentPosition
        currentPosition = next
        assert(currentPosition > rangeEnd)
      }
    case .any:
      let anyMatchesNewline = payload.anyMatchesNewline
      while true {
        guard let next = matchRegexDot(
          at: currentPosition,
          limitedBy: end,
          anyMatchesNewline: anyMatchesNewline,
          isScalarSemantics: isScalarSemantics)
        else {
          break
        }
        numMatches += 1
        if numMatches == minTrips {
          rangeStart = next
        }
        rangeEnd = currentPosition
        currentPosition = next
        assert(currentPosition > rangeEnd)
      }
    }

    guard numMatches >= minTrips else {
      return nil
    }

    guard numMatches > minTrips else {
      // Consumed no input, no point saved
      return (currentPosition, nil)
    }
    assert(rangeStart <= rangeEnd)

    // NOTE: We can't assert that rangeEnd trails currentPosition by one
    // position, because newline-sequence in scalar semantic mode still
    // matches two scalars

    return (currentPosition, rangeStart..<rangeEnd)
  }

  /// Specialized quantify instruction interpreter for `+`
  fileprivate func runEagerNOrMoreQuantify(
    _ payload: QuantifyPayload,
    asciiBitset: ASCIIBitset?, // Necessary ugliness...
    at currentPosition: Index,
    limitedBy end: Index
  ) -> (Index, savePointRange: Range<Index>?)? {
    assert(payload.quantKind == .eager
           && payload.maxExtraTrips == nil)

    return _runEagerNOrMoreQuantify(
      payload,
      minTrips: payload.minTrips,
      asciiBitset: asciiBitset,
      at: currentPosition,
      limitedBy: end)
  }

  /// Specialized quantify instruction interpreter for `+`
  fileprivate func runEagerOneOrMoreQuantify(
    _ payload: QuantifyPayload,
    asciiBitset: ASCIIBitset?, // Necessary ugliness...
    at currentPosition: Index,
    limitedBy end: Index
  ) -> (Index, savePointRange: Range<Index>?)? {
    assert(payload.quantKind == .eager
           && payload.minTrips == 1
           && payload.maxExtraTrips == nil)

    return _runEagerNOrMoreQuantify(
      payload,
      minTrips: 1,
      asciiBitset: asciiBitset,
      at: currentPosition,
      limitedBy: end)
  }

  /// Specialized quantify instruction interpreter for ?
  fileprivate func runZeroOrOneQuantify(
    _ payload: QuantifyPayload,
    asciiBitset: ASCIIBitset?, // Necessary ugliness...
    at currentPosition: Index,
    limitedBy end: Index
  ) -> (Index, makeSavePoint: Bool) {
    assert(payload.minTrips == 0
           && payload.maxExtraTrips == 1)
    guard let next = doQuantifyMatch(
      payload,
      asciiBitset: asciiBitset,
      at: currentPosition,
      limitedBy: end
    ) else {
      return (currentPosition, false)
    }
    return (next, payload.quantKind != .possessive)
  }  
}


