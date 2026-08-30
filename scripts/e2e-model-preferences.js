'use strict';

// Restart real Electron processes against isolated data; never touch user settings/models.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { _electron: electron } = require('playwright');

const ROOT = path.resolve(__dirname, '..');

async function run() {
  const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'wst-model-preferences-'));
  let app;
  try {
    for (const [expected, next] of [
      ['1.8b', '7b'],
      ['7b', '1.8b'],
      ['1.8b', null],
    ]) {
      app = await electron.launch({
        ...(process.env.WST_E2E_EXECUTABLE ? { executablePath: process.env.WST_E2E_EXECUTABLE } : {}),
        args: process.env.WST_E2E_EXECUTABLE ? [] : ['.'],
        cwd: ROOT,
        timeout: 60000,
        env: { ...process.env, ELECTRON_DISABLE_SANDBOX: '1', E2E_SMOKE: '1', WHISPER_PORTABLE_DATA: userData },
      });
      const window = await app.firstWindow();
      await window.waitForLoadState('domcontentloaded');
      await window.waitForFunction(() => !!window.__E2E_HOOK__);
      await window.waitForFunction((id) => document.querySelector('#localModelSelect')?.value === id, expected);
      // Let the asynchronous settings loader finish before checking the default case too.
      await window.evaluate(() => loadSavedSettings());
      assert.equal(await window.locator('#localModelSelect').inputValue(), expected);
      const catalog = await window.evaluate(() => window.electronAPI.localModelList());
      assert.equal(catalog.length, 2);
      for (const model of catalog) assert.match(model.displayName, /Q8/);
      if (next) {
        await window.locator('#localModelSelect').selectOption(next, { force: true });
        await window.waitForFunction(async (id) => {
          const saved = await window.electronAPI.loadApiKeys();
          return saved?.keys?.localModelId === id;
        }, next);
        // Saving another preference must not erase the model selection.
        await window.evaluate(() => window.electronAPI.saveApiKeys({ uiLanguage: 'en' }));
      }
      await app.close();
      app = null;
      console.log(`[ModelPreferences] restart restored ${expected}${next ? `; saved ${next}` : ''}`);
    }
  } finally {
    if (app) await app.close();
    fs.rmSync(userData, { recursive: true, force: true });
  }
}

run().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
