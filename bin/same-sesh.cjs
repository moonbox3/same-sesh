#!/usr/bin/env node
// npm is only a delivery mechanism. The installed script and watcher are native.
const { spawnSync } = require('node:child_process');
const { resolve } = require('node:path');
if (process.platform !== 'darwin') {
  console.error('This setup preview supports macOS terminals. On Windows, use same-sesh.cmd from the repository.');
  process.exit(1);
}
const result = spawnSync('/usr/bin/osascript', ['-l', 'JavaScript', resolve(__dirname, '..', 'same-sesh'), ...process.argv.slice(2)], { stdio: 'inherit' });
if (result.error) console.error(result.error.message);
process.exit(result.status ?? 1);
