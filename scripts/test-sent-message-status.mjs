import { readFileSync, writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
const temp = mkdtempSync(join(tmpdir(), 'cryptoscreen-status-tests-'));
try {
  // Compile the actual production model/store with its real API, replacing only HTTP transport.
  const source = readFileSync('PrivacyScreen/SealedMessageRootView.swift', 'utf8');
  const start = source.indexOf('enum SentMessageStatus:');
  const end = source.indexOf('struct SealedMessageRootView: View');
  if (start < 0 || end <= start) throw new Error('Could not locate the production sent-message model/store');
  const extracted = join(temp, 'SealedMessageStore.swift');
  writeFileSync(extracted, 'import Foundation\nimport SwiftUI\nprivate let sentMessagesStorageKey = "cryptoscreen.sentMessages"\n' + source.slice(start, end));
  const binary = join(temp, 'status-checks');
  execFileSync('xcrun', ['swiftc', extracted, 'PrivacyScreen/SealedMessageCrypto.swift', 'PrivacyScreen/SealedMessageAPI.swift', 'tests/SentMessageStatusChecks.swift', '-o', binary], { stdio: 'inherit' });
  execFileSync(binary, [], { stdio: 'inherit' });
} finally {
  rmSync(temp, {recursive:true, force:true});
}
