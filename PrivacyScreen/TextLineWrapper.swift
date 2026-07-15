import UIKit

struct ReaderLine: Identifiable, Equatable {
  let id: Int
  let text: String
  let attributedText: AttributedString
}

enum TextLineWrapper {
  static func attributedParagraph(_ text: String) -> AttributedString {
    let blocks = markdownBlocks(in: text)
    var output = AttributedString()

    for (index, block) in blocks.enumerated() {
      if index > 0 {
        output += AttributedString("\n")
      }

      output += attributedString(for: block.firstPrefix + block.runs)
    }

    return output
  }

  static func wrap(_ text: String, width: CGFloat, fontSize: CGFloat) -> [ReaderLine] {
    let usableWidth = max(width, 80)
    let font = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    let blocks = markdownBlocks(in: text)
    var rawLines: [MarkdownLine] = []

    for block in blocks {
      rawLines.append(contentsOf: wrap(block, maxWidth: usableWidth, font: font))
    }

    if rawLines.isEmpty {
      return [ReaderLine(id: 0, text: "", attributedText: AttributedString(""))]
    }

    return rawLines.enumerated().map { offset, line in
      ReaderLine(id: offset, text: line.text, attributedText: attributedString(for: line.runs))
    }
  }

  private static func markdownBlocks(in text: String) -> [MarkdownBlock] {
    let rawLines = text.components(separatedBy: .newlines)
    let blocks = rawLines.map { rawLine in
      let trimmedLeft = rawLine.trimmingCharacters(in: .whitespaces)

      if trimmedLeft.hasPrefix("- ") {
        let content = String(trimmedLeft.dropFirst(2))
        return MarkdownBlock(
          firstPrefix: [MarkdownRun(text: "• ")],
          continuationPrefix: [MarkdownRun(text: "  ")],
          runs: parseInlineMarkdown(content)
        )
      }

      if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
        return MarkdownBlock(firstPrefix: [], continuationPrefix: [], runs: [MarkdownRun(text: "")])
      }

      return MarkdownBlock(firstPrefix: [], continuationPrefix: [], runs: parseInlineMarkdown(rawLine))
    }

    return blocks
  }

  private static func wrap(_ block: MarkdownBlock, maxWidth: CGFloat, font: UIFont) -> [MarkdownLine] {
    var lines: [MarkdownLine] = []
    var currentRuns = block.firstPrefix
    var currentText = block.firstPrefix.map(\.text).joined()

    let tokens = tokenize(block.runs)
    for token in tokens {
      if token.text.trimmingCharacters(in: .whitespaces).isEmpty,
         currentText.trimmingCharacters(in: .whitespaces).isEmpty {
        continue
      }

      let candidate = currentText + token.text
      if currentText.isEmpty || measuredWidth(candidate, font: font) <= maxWidth {
        append(token, to: &currentRuns, text: &currentText)
        continue
      }

      if !currentText.trimmingCharacters(in: .whitespaces).isEmpty {
        lines.append(MarkdownLine(runs: currentRuns, text: currentText.trimmingCharacters(in: .whitespaces)))
      }

      currentRuns = block.continuationPrefix
      currentText = block.continuationPrefix.map(\.text).joined()

      if token.text.trimmingCharacters(in: .whitespaces).isEmpty {
        continue
      }

      if measuredWidth(currentText + token.text, font: font) <= maxWidth {
        append(token, to: &currentRuns, text: &currentText)
      } else {
        let splitRuns = splitTokenIfNeeded(token, prefixRuns: block.continuationPrefix, maxWidth: maxWidth, font: font)
        for splitRun in splitRuns.dropLast() {
          lines.append(splitRun)
        }

        if let last = splitRuns.last {
          currentRuns = last.runs
          currentText = last.text
        }
      }
    }

    if currentText.trimmingCharacters(in: .whitespaces).isEmpty {
      if lines.isEmpty {
        lines.append(MarkdownLine(runs: [MarkdownRun(text: "")], text: ""))
      }
    } else {
      lines.append(MarkdownLine(runs: currentRuns, text: currentText.trimmingCharacters(in: .whitespaces)))
    }

    return lines
  }

  private static func splitTokenIfNeeded(
    _ token: MarkdownRun,
    prefixRuns: [MarkdownRun],
    maxWidth: CGFloat,
    font: UIFont
  ) -> [MarkdownLine] {
    var lines: [MarkdownLine] = []
    var currentRuns = prefixRuns
    var currentText = prefixRuns.map(\.text).joined()

    for character in token.text {
      let next = String(character)
      let candidate = currentText + next

      if currentText == prefixRuns.map(\.text).joined() || measuredWidth(candidate, font: font) <= maxWidth {
        append(token.copy(text: next), to: &currentRuns, text: &currentText)
      } else {
        lines.append(MarkdownLine(runs: currentRuns, text: currentText))
        currentRuns = prefixRuns
        currentText = prefixRuns.map(\.text).joined()
        append(token.copy(text: next), to: &currentRuns, text: &currentText)
      }
    }

    if !currentText.isEmpty {
      lines.append(MarkdownLine(runs: currentRuns, text: currentText))
    }

    return lines
  }

  private static func tokenize(_ runs: [MarkdownRun]) -> [MarkdownRun] {
    var tokens: [MarkdownRun] = []

    for run in runs {
      var current = ""
      var currentIsWhitespace: Bool?

      for character in run.text {
        let isWhitespace = character.isWhitespace

        if let currentIsWhitespace, currentIsWhitespace != isWhitespace {
          tokens.append(run.copy(text: current))
          current = ""
        }

        current.append(character)
        currentIsWhitespace = isWhitespace
      }

      if !current.isEmpty {
        tokens.append(run.copy(text: current))
      }
    }

    return tokens
  }

  private static func append(_ run: MarkdownRun, to runs: inout [MarkdownRun], text: inout String) {
    guard !run.text.isEmpty else {
      return
    }

    if let last = runs.last, last.canMerge(with: run) {
      runs[runs.count - 1] = last.copy(text: last.text + run.text)
    } else {
      runs.append(run)
    }
    text += run.text
  }

  private static func parseInlineMarkdown(_ text: String) -> [MarkdownRun] {
    let characters = Array(text)
    var runs: [MarkdownRun] = []
    var index = 0

    while index < characters.count {
      if characters[index] == "[",
         let parsedLink = parseMarkdownLink(characters, startIndex: index) {
        runs.append(MarkdownRun(text: parsedLink.label, link: parsedLink.url))
        index = parsedLink.nextIndex
        continue
      }

      if let parsedURL = parsePlainURL(characters, startIndex: index) {
        runs.append(MarkdownRun(text: parsedURL.text, link: parsedURL.url))
        index = parsedURL.nextIndex
        continue
      }

      if characters[index] == "*" || characters[index] == "_",
         let parsedStyle = parseDelimitedStyle(characters, startIndex: index) {
        runs.append(
          MarkdownRun(
            text: parsedStyle.text,
            isBold: characters[index] == "*",
            isItalic: characters[index] == "_"
          )
        )
        index = parsedStyle.nextIndex
        continue
      }

      var plain = ""
      while index < characters.count,
            characters[index] != "[",
            characters[index] != "*",
            characters[index] != "_" {
        if parsePlainURL(characters, startIndex: index) != nil {
          break
        }

        plain.append(characters[index])
        index += 1
      }

      if !plain.isEmpty {
        runs.append(MarkdownRun(text: plain))
      }
    }

    return runs
  }

  private static func parseMarkdownLink(
    _ characters: [Character],
    startIndex: Int
  ) -> (label: String, url: URL, nextIndex: Int)? {
    guard characters[startIndex] == "[" else {
      return nil
    }

    var labelEnd = startIndex + 1
    while labelEnd < characters.count, characters[labelEnd] != "]" {
      labelEnd += 1
    }

    guard labelEnd + 1 < characters.count,
          labelEnd > startIndex + 1,
          characters[labelEnd + 1] == "(" else {
      return nil
    }

    var urlEnd = labelEnd + 2
    while urlEnd < characters.count, characters[urlEnd] != ")" {
      urlEnd += 1
    }

    guard urlEnd < characters.count else {
      return nil
    }

    let label = String(characters[(startIndex + 1)..<labelEnd])
    let urlText = String(characters[(labelEnd + 2)..<urlEnd])
    guard let url = sanitizedExternalURL(urlText) else {
      return nil
    }

    return (label, url, urlEnd + 1)
  }

  private static func parsePlainURL(
    _ characters: [Character],
    startIndex: Int
  ) -> (text: String, url: URL, nextIndex: Int)? {
    let remaining = String(characters[startIndex...])
    guard remaining.hasPrefix("https://") || remaining.hasPrefix("http://") else {
      return nil
    }

    var urlText = ""
    var index = startIndex
    while index < characters.count, !characters[index].isWhitespace {
      urlText.append(characters[index])
      index += 1
    }

    let trimmedURLText = urlText.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:"))
    guard let url = sanitizedExternalURL(trimmedURLText) else {
      return nil
    }

    return (trimmedURLText, url, startIndex + trimmedURLText.count)
  }

  private static func parseDelimitedStyle(
    _ characters: [Character],
    startIndex: Int
  ) -> (text: String, nextIndex: Int)? {
    let delimiter = characters[startIndex]
    var endIndex = startIndex + 1

    while endIndex < characters.count, characters[endIndex] != delimiter {
      endIndex += 1
    }

    guard endIndex < characters.count, endIndex > startIndex + 1 else {
      return nil
    }

    let text = String(characters[(startIndex + 1)..<endIndex])
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return nil
    }

    return (text, endIndex + 1)
  }

  private static func sanitizedExternalURL(_ text: String) -> URL? {
    guard let url = URL(string: text),
          let scheme = url.scheme?.lowercased(),
          scheme == "http" || scheme == "https" else {
      return nil
    }

    return url
  }

  private static func attributedString(for runs: [MarkdownRun]) -> AttributedString {
    var output = AttributedString()

    for run in runs {
      var piece = AttributedString(run.text)
      var intent = InlinePresentationIntent()

      if run.isBold {
        intent.insert(.stronglyEmphasized)
      }
      if run.isItalic {
        intent.insert(.emphasized)
      }
      if !intent.isEmpty {
        piece.inlinePresentationIntent = intent
      }
      if let link = run.link {
        piece.link = link
        piece.foregroundColor = .green
        piece.underlineStyle = .single
      }

      output += piece
    }

    return output
  }

  private static func measuredWidth(_ text: String, font: UIFont) -> CGFloat {
    (text as NSString).size(withAttributes: [.font: font]).width
  }
}

private struct MarkdownBlock {
  let firstPrefix: [MarkdownRun]
  let continuationPrefix: [MarkdownRun]
  let runs: [MarkdownRun]
}

private struct MarkdownLine {
  let runs: [MarkdownRun]
  let text: String
}

private struct MarkdownRun {
  let text: String
  var isBold = false
  var isItalic = false
  var link: URL?

  func copy(text: String) -> MarkdownRun {
    MarkdownRun(text: text, isBold: isBold, isItalic: isItalic, link: link)
  }

  func canMerge(with other: MarkdownRun) -> Bool {
    isBold == other.isBold && isItalic == other.isItalic && link == other.link
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
      guard !character.isWhitespace else {
        return character
      }

      return glyphs.randomElement(using: &generator) ?? "#"
    })
  }

  static func resolvingText(for text: String, seed: Int, progress: Double, tick: Int) -> String {
    let characters = Array(text)
    let revealCount = Int((Double(characters.count) * progress).rounded(.down))
    var generator = SeededGenerator(seed: UInt64(seed + 31 + tick) &* 0xBF58476D1CE4E5B9)

    return String(characters.enumerated().map { index, character in
      if character.isWhitespace || index < revealCount {
        return character
      }

      return glyphs.randomElement(using: &generator) ?? "#"
    })
  }
}
