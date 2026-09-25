// Shared application code and version; only the installer differs from macOS.
module.exports = {
  extends: null,
  appId: 'org.lipidflow.desktop', productName: 'LipidFlow',
  copyright: 'Copyright © 2026 Wang Lab',
  directories: {output: 'release/windows'},
  files: ['dist/**/*', 'electron/**/*', 'package.json'],
  extraResources: [{from:'backend',to:'backend'}, {from:'runtime/R',to:'runtime/R',filter:['**/*','!library/lipidflow/POS{,/**/*}','!library/lipidflow/NEG{,/**/*}']}, {from:'docs/help',to:'help'}],
  afterPack: require('../scripts/verify-packaged-resources.cjs'),
  beforePack: async context => {
    if (context.electronPlatformName !== 'win32') throw Error('Use this configuration only for Windows.');
    require('../scripts/check-runtime.cjs').checkRuntime(context.packager.projectDir, 'win32');
  },
  win: {target: [{target:'nsis',arch:['x64']}], icon:'assets/icon.png',
    artifactName:'LipidFlow-${version}-windows-${arch}-setup.${ext}'},
  nsis: {oneClick:false,perMachine:false,allowToChangeInstallationDirectory:true,
    createDesktopShortcut:true,createStartMenuShortcut:true,deleteAppDataOnUninstall:false,
    shortcutName:'LipidFlow'}
};
