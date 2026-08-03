//
//  AgentThreadOpener.swift
//  Dayflow
//
//  Opens a recap thread from the card's "Source" button.
//
//  This intentionally uses only explicit URL/file actions. Dayflow must not
//  script another application or create terminal windows as a side effect of
//  viewing a recap. That keeps the source link predictable and avoids asking
//  macOS for Automation permission.
//

import AppKit
import Foundation

enum AgentThreadOpener {

  @MainActor
  static func open(_ thread: AgentThread) {
    guard !thread.sessionPath.isEmpty else { return }
    switch thread.source {
    case .codex:
      openCodexThread(sessionPath: thread.sessionPath)
    case .claude:
      revealInFinder(thread.sessionPath)
    }
  }

  // MARK: - Codex: deep link into the desktop app

  @MainActor
  private static func openCodexThread(sessionPath: String) {
    guard
      let threadID = codexThreadID(fromSessionPath: sessionPath),
      let url = URL(string: "codex://threads/\(threadID)"),
      NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    else {
      revealInFinder(sessionPath)
      return
    }
    NSWorkspace.shared.open(url)
  }

  /// rollout-2026-07-06T19-45-03-<uuid>.jsonl → <uuid>
  /// (The UUID is the last five hyphen-separated groups of the stem.)
  static func codexThreadID(fromSessionPath path: String) -> String? {
    let stem = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    guard stem.hasPrefix("rollout-") else { return nil }
    let parts = stem.split(separator: "-")
    guard parts.count >= 11 else { return nil }
    return parts.suffix(5).joined(separator: "-")
  }

  @MainActor
  private static func revealInFinder(_ path: String) {
    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
  }
}
