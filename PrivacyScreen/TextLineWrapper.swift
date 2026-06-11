import UIKit

struct ReaderLine: Identifiable, Equatable {
  let id: Int
  let text: String
}

enum TextLineWrapper {
  static func wrap(_ text: String, width: CGFloat, fontSize: CGFloat) -> [ReaderLine] {
    let usableWidth = max(width, 80)
    let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    let words = text
      .replacingOccurrences(of: "\n", with: " ")
      .split(separator: " ", omittingEmptySubsequences: true)
      .map(String.init)

    var rawLines: [String] = []
    var currentLine = ""

    for word in words {
      let parts = splitWordIfNeeded(word, maxWidth: usableWidth, font: font)

      for part in parts {
        if currentLine.isEmpty {
          currentLine = part
          continue
        }

        let candidate = "\(currentLine) \(part)"
        if measuredWidth(candidate, font: font) <= usableWidth {
          currentLine = candidate
        } else {
          rawLines.append(currentLine)
          currentLine = part
        }
      }
    }

    if !currentLine.isEmpty {
      rawLines.append(currentLine)
    }

    if rawLines.isEmpty {
      return [ReaderLine(id: 0, text: "")]
    }

    return rawLines.enumerated().map { ReaderLine(id: $0.offset, text: $0.element) }
  }

  private static func splitWordIfNeeded(_ word: String, maxWidth: CGFloat, font: UIFont) -> [String] {
    guard measuredWidth(word, font: font) > maxWidth else {
      return [word]
    }

    var chunks: [String] = []
    var currentChunk = ""

    for character in word {
      let candidate = currentChunk + String(character)

      if currentChunk.isEmpty || measuredWidth(candidate, font: font) <= maxWidth {
        currentChunk = candidate
      } else {
        chunks.append(currentChunk)
        currentChunk = String(character)
      }
    }

    if !currentChunk.isEmpty {
      chunks.append(currentChunk)
    }

    return chunks
  }

  private static func measuredWidth(_ text: String, font: UIFont) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: font]).width
  }
}

struct SeededGenerator: RandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed == 0 ? 0x6A09E667F3BCC909 : seed
  }

  mutating func next() -> UInt64 {
    state = state &* 2862933555777941757 &+ 3037000493
    return state
  }
}

enum CipherText {
  private static let glyphs = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789#$%&*+-/<>[]{}")

  static func hiddenText(for text: String, seed: Int) -> String {
    var generator = SeededGenerator(seed: UInt64(seed + 1) &* 0x9E3779B97F4A7C15)

    return String(text.map { character in
      guard character != " " else {
        return " "
      }

      return glyphs.randomElement(using: &generator) ?? "#"
    })
  }

  static func resolvingText(for text: String, seed: Int, progress: Double, tick: Int) -> String {
    let characters = Array(text)
    let revealCount = Int((Double(characters.count) * progress).rounded(.down))
    var generator = SeededGenerator(seed: UInt64(seed + 31 + tick) &* 0xBF58476D1CE4E5B9)

    return String(characters.enumerated().map { index, character in
      if character == " " || index < revealCount {
        return character
      }

      return glyphs.randomElement(using: &generator) ?? "#"
    })
  }
}
