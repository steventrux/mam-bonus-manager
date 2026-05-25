#!/usr/bin/env node
'use strict';

const fs = require('fs');
const path = require('path');
const { chromium } = require('playwright');

const BASE_URL = process.env.MAM_BASE_URL || 'https://www.myanonamouse.net';
const PROFILE_DIR = process.env.MAM_BROWSER_PROFILE_DIR || path.resolve(process.cwd(), '.mam-browser-profile');
const HEADLESS = String(process.env.MAM_BROWSER_HEADLESS || '1') !== '0';
const TIMEOUT = Number(process.env.MAM_BROWSER_TIMEOUT || 30000);

function usage() {
  console.error(`Usage:
  node scripts/mam-browser-gift.js check-login
  node scripts/mam-browser-gift.js gift <uid> <amount>

Environment:
  MAM_BROWSER_PROFILE_DIR   Persistent Chromium profile directory. Default: ./.mam-browser-profile
  MAM_BROWSER_HEADLESS      1=headless, 0=visible browser. Default: 1
  MAM_BROWSER_TIMEOUT       Timeout in ms. Default: 30000
  MAM_LOGIN_EMAIL           MAM login email. Required only when automatic login is needed
  MAM_LOGIN_PASSWORD        MAM login password. Prefer MAM_LOGIN_PASSWORD_FILE
  MAM_LOGIN_PASSWORD_FILE   File containing the MAM login password`);
}

function printJson(payload) {
  process.stdout.write(`${JSON.stringify(payload)}\n`);
}

function readPassword() {
  if (process.env.MAM_LOGIN_PASSWORD_FILE) {
    return fs.readFileSync(process.env.MAM_LOGIN_PASSWORD_FILE, 'utf8').trim();
  }

  return process.env.MAM_LOGIN_PASSWORD || '';
}

function hasLoginCredentials() {
  return Boolean(process.env.MAM_LOGIN_EMAIL && (process.env.MAM_LOGIN_PASSWORD || process.env.MAM_LOGIN_PASSWORD_FILE));
}

function validatePositiveInteger(value, fieldName) {
  if (!/^[0-9]+$/.test(String(value || ''))) {
    throw new Error(`${fieldName}_must_be_a_positive_integer`);
  }

  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed <= 0) {
    throw new Error(`${fieldName}_must_be_a_positive_integer`);
  }

  return parsed;
}

async function readSummary(page) {
  return await page.evaluate(async () => {
    const response = await fetch('/jsonLoad.php?snatch_summary', {
      credentials: 'same-origin',
      cache: 'no-store',
    });

    const text = await response.text();
    let data = null;
    try {
      data = JSON.parse(text);
    } catch (error) {
      return {
        ok: false,
        httpStatus: response.status,
        contentType: response.headers.get('content-type') || '',
        error: 'non_json_response',
        preview: text.slice(0, 300),
      };
    }

    return {
      ok: response.ok,
      httpStatus: response.status,
      contentType: response.headers.get('content-type') || '',
      data,
    };
  });
}

function summaryIdentity(summary) {
  const uid = summary && summary.data ? summary.data.uid : null;
  const username = summary && summary.data ? summary.data.username : null;
  const seedbonus = summary && summary.data ? summary.data.seedbonus : null;
  return { uid, username, seedbonus };
}

async function ensureLogin(page) {
  const email = process.env.MAM_LOGIN_EMAIL || '';
  const password = readPassword();

  if (!email || !password) {
    return {
      attempted: false,
      success: false,
      error: 'missing_login_credentials',
    };
  }

  await page.goto(`${BASE_URL}/login.php`, { waitUntil: 'domcontentloaded', timeout: TIMEOUT });

  const emailInput = page.locator('input[name="email"]');
  const passwordInput = page.locator('input[name="password"]');
  const rememberInput = page.locator('input[name="rememberMe"]');

  await emailInput.waitFor({ state: 'visible', timeout: TIMEOUT });
  await emailInput.fill(email);
  await passwordInput.fill(password);

  if (await rememberInput.count()) {
    await rememberInput.check().catch(() => {});
  }

  await Promise.all([
    page.waitForLoadState('domcontentloaded', { timeout: TIMEOUT }).catch(() => {}),
    page.locator('input[type="submit"]').first().click(),
  ]);

  await page.waitForTimeout(1500);
  await page.goto(BASE_URL, { waitUntil: 'domcontentloaded', timeout: TIMEOUT });

  const summary = await readSummary(page);
  const { uid, username, seedbonus } = summaryIdentity(summary);

  if (summary.ok && uid) {
    return {
      attempted: true,
      success: true,
      uid,
      username,
      seedbonus,
    };
  }

  return {
    attempted: true,
    success: false,
    error: summary.error || 'login_failed_or_invalid_summary',
    httpStatus: summary.httpStatus,
    contentType: summary.contentType,
    preview: summary.preview,
  };
}

async function ensureLoggedIn(page) {
  await page.goto(BASE_URL, { waitUntil: 'domcontentloaded', timeout: TIMEOUT });

  const initialSummary = await readSummary(page);
  const initialIdentity = summaryIdentity(initialSummary);

  if (initialSummary.ok && initialIdentity.uid) {
    return {
      success: true,
      loggedIn: true,
      loginAttempted: false,
      uid: initialIdentity.uid,
      username: initialIdentity.username,
      seedbonus: initialIdentity.seedbonus,
    };
  }

  if (!hasLoginCredentials()) {
    return {
      success: false,
      loggedIn: false,
      loginAttempted: false,
      error: initialSummary.error || 'not_logged_in_or_invalid_summary',
      httpStatus: initialSummary.httpStatus,
      contentType: initialSummary.contentType,
      preview: initialSummary.preview,
      hint: 'Set MAM_LOGIN_EMAIL and MAM_LOGIN_PASSWORD_FILE to enable automatic login.',
    };
  }

  const loginResult = await ensureLogin(page);
  if (loginResult.success) {
    return {
      success: true,
      loggedIn: true,
      loginAttempted: true,
      uid: loginResult.uid,
      username: loginResult.username,
      seedbonus: loginResult.seedbonus,
    };
  }

  return {
    success: false,
    loggedIn: false,
    loginAttempted: loginResult.attempted,
    error: loginResult.error,
    httpStatus: loginResult.httpStatus,
    contentType: loginResult.contentType,
    preview: loginResult.preview,
  };
}

async function withBrowser(callback) {
  fs.mkdirSync(PROFILE_DIR, { recursive: true });

  const context = await chromium.launchPersistentContext(PROFILE_DIR, {
    headless: HEADLESS,
    viewport: { width: 1280, height: 900 },
    timeout: TIMEOUT,
  });

  try {
    const page = context.pages()[0] || await context.newPage();
    page.setDefaultTimeout(TIMEOUT);
    return await callback(page);
  } finally {
    await context.close();
  }
}

async function checkLogin() {
  return await withBrowser(async (page) => {
    const loginState = await ensureLoggedIn(page);

    if (loginState.success) {
      printJson({
        success: true,
        mode: 'check-login',
        loggedIn: true,
        loginAttempted: loginState.loginAttempted,
        uid: loginState.uid,
        username: loginState.username,
        seedbonus: loginState.seedbonus,
        profileDir: PROFILE_DIR,
        headless: HEADLESS,
      });
      return 0;
    }

    printJson({
      success: false,
      mode: 'check-login',
      loggedIn: false,
      loginAttempted: loginState.loginAttempted,
      error: loginState.error,
      httpStatus: loginState.httpStatus,
      contentType: loginState.contentType,
      preview: loginState.preview,
      hint: loginState.hint,
      profileDir: PROFILE_DIR,
      headless: HEADLESS,
    });
    return loginState.loginAttempted ? 3 : 2;
  });
}

async function sendGift(uidArg, amountArg) {
  const uid = validatePositiveInteger(uidArg, 'uid');
  const amount = validatePositiveInteger(amountArg, 'amount');

  return await withBrowser(async (page) => {
    const loginState = await ensureLoggedIn(page);
    if (!loginState.success) {
      printJson({
        success: false,
        mode: 'gift',
        uid,
        amount,
        loggedIn: false,
        loginAttempted: loginState.loginAttempted,
        error: loginState.error || 'not_logged_in',
        httpStatus: loginState.httpStatus,
        contentType: loginState.contentType,
        preview: loginState.preview,
      });
      return 3;
    }

    const beforeSeedbonus = loginState.seedbonus;
    const result = await page.evaluate(async ({ uid, amount }) => {
      const response = await fetch(`/json/bonusBuy.php?spendtype=gift&amount=${amount}&giftTo=${uid}`, {
        credentials: 'same-origin',
        cache: 'no-store',
      });

      const text = await response.text();
      let data = null;
      try {
        data = JSON.parse(text);
      } catch (error) {
        return {
          success: false,
          httpStatus: response.status,
          contentType: response.headers.get('content-type') || '',
          error: 'non_json_response',
          preview: text.slice(0, 300),
        };
      }

      return {
        success: data.success === true,
        httpStatus: response.status,
        contentType: response.headers.get('content-type') || '',
        error: data.error || null,
        data,
      };
    }, { uid, amount });

    const afterSummary = await readSummary(page).catch(() => null);
    const afterIdentity = summaryIdentity(afterSummary);

    printJson({
      success: result.success,
      mode: 'gift',
      uid,
      amount,
      loggedIn: true,
      loginAttempted: loginState.loginAttempted,
      accountUid: loginState.uid,
      accountUsername: loginState.username,
      beforeSeedbonus,
      afterSeedbonus: afterIdentity.seedbonus,
      httpStatus: result.httpStatus,
      contentType: result.contentType,
      error: result.error || undefined,
      response: result.data || undefined,
      preview: result.preview || undefined,
      profileDir: PROFILE_DIR,
      headless: HEADLESS,
    });

    return result.success ? 0 : 4;
  });
}

async function main() {
  const command = process.argv[2];

  if (!command || command === '-h' || command === '--help') {
    usage();
    process.exit(command ? 0 : 1);
  }

  let exitCode;
  try {
    if (command === 'check-login') {
      exitCode = await checkLogin();
    } else if (command === 'gift') {
      exitCode = await sendGift(process.argv[3], process.argv[4]);
    } else {
      printJson({ success: false, error: `unsupported_command: ${command}` });
      usage();
      exitCode = 1;
    }

    process.exit(exitCode);
  } catch (error) {
    printJson({
      success: false,
      mode: command,
      error: error.message,
      stack: process.env.MAM_BROWSER_DEBUG === '1' ? error.stack : undefined,
    });
    process.exit(1);
  }
}

main();
