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

Environment:
  MAM_BROWSER_PROFILE_DIR   Persistent Chromium profile directory. Default: ./.mam-browser-profile
  MAM_BROWSER_HEADLESS      1=headless, 0=visible browser. Default: 1
  MAM_BROWSER_TIMEOUT       Timeout in ms. Default: 30000
  MAM_LOGIN_EMAIL           Optional, not used yet in check-login mode
  MAM_LOGIN_PASSWORD        Optional, not used yet in check-login mode
  MAM_LOGIN_PASSWORD_FILE   Optional, not used yet in check-login mode`);
}

function printJson(payload) {
  process.stdout.write(`${JSON.stringify(payload)}\n`);
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

async function checkLogin() {
  fs.mkdirSync(PROFILE_DIR, { recursive: true });

  const context = await chromium.launchPersistentContext(PROFILE_DIR, {
    headless: HEADLESS,
    viewport: { width: 1280, height: 900 },
    timeout: TIMEOUT,
  });

  try {
    const page = context.pages()[0] || await context.newPage();
    page.setDefaultTimeout(TIMEOUT);

    await page.goto(BASE_URL, { waitUntil: 'domcontentloaded', timeout: TIMEOUT });

    const summary = await readSummary(page);
    const uid = summary && summary.data ? summary.data.uid : null;
    const username = summary && summary.data ? summary.data.username : null;
    const seedbonus = summary && summary.data ? summary.data.seedbonus : null;

    if (summary.ok && uid) {
      printJson({
        success: true,
        mode: 'check-login',
        loggedIn: true,
        uid,
        username,
        seedbonus,
        profileDir: PROFILE_DIR,
        headless: HEADLESS,
      });
      return 0;
    }

    printJson({
      success: false,
      mode: 'check-login',
      loggedIn: false,
      error: summary.error || 'not_logged_in_or_invalid_summary',
      httpStatus: summary.httpStatus,
      contentType: summary.contentType,
      preview: summary.preview,
      profileDir: PROFILE_DIR,
      headless: HEADLESS,
    });
    return 2;
  } finally {
    await context.close();
  }
}

async function main() {
  const command = process.argv[2];

  if (!command || command === '-h' || command === '--help') {
    usage();
    process.exit(command ? 0 : 1);
  }

  if (command !== 'check-login') {
    printJson({ success: false, error: `unsupported_command: ${command}` });
    usage();
    process.exit(1);
  }

  try {
    const exitCode = await checkLogin();
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
