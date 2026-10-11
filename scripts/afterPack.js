// Ad-hoc signs the finished Mac app. Without any signature, Apple Silicon Macs report
// the app as "damaged". (A paid Developer ID would replace this.)
const { execSync } = require('child_process');
const path = require('path');

exports.default = async function afterPack(context) {
  if (context.electronPlatformName !== 'darwin') return;
  // Universal builds pack x64 and arm64 first and merge them; only sign the merged app,
  // otherwise the two halves no longer match and the merge fails.
  const { Arch } = require('builder-util');
  if (context.arch !== Arch.universal) return;
  const app = path.join(context.appOutDir, `${context.packager.appInfo.productFilename}.app`);
  console.log(`  • ad-hoc signing ${app}`);
  execSync(`codesign --force --deep --sign - "${app}"`, { stdio: 'inherit' });
};
