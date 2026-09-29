import test from 'node:test';
import assert from 'node:assert/strict';
import { expandAction, parseScript, toScript, tokenize } from '../src/server/dsl';
import { findElement, parseElements } from '../src/server/elements';
import { safeName } from '../src/server/store';
import { shellQuote } from '../src/server/process';

test('quoted strings, escaped quotes, Unicode and comments survive parsing', () => {
  assert.deepEqual(tokenize('type "Name" "Müller #1 \\"quoted\\"" # comment'.replaceAll('\\\\"', '\\"')), ['type', 'Name', 'Müller #1 "quoted"']);
  assert.deepEqual(parseScript('tap "Sign in"\ntype "Email" "a@b.de"\nwait_for "Welcome"\n'), [{ action: 'tap', target: 'Sign in' }, { action: 'type', target: 'Email', text: 'a@b.de' }, { action: 'wait_for', target: 'Welcome', timeout: 10000 }]);
});
test('parameters cannot inject new commands and missing parameters fail', () => {
  const action = parseScript('type "${value}"')[0]!;
  const expanded = expandAction(action, { value: 'x"\nlaunch "evil.package"\n#' });
  assert.equal(expanded.action, 'type');
  if (expanded.action === 'type') assert.equal(expanded.text, 'x"\nlaunch "evil.package"\n#');
  assert.throws(() => expandAction(action, {}), /Missing parameter/);
  assert.throws(() => expandAction(action, Object.create({ value: 'inherited' }) as Record<string, string>), /Missing parameter/);
});
test('invalid syntax, arity and unsafe numeric inputs fail with line numbers', () => {
  for (const source of ['tap "unterminated', 'tap "Hi" garbage extra', 'wait -1', 'swipe 0 0 1 NaN', 'type "abc"suffix', 'unknown "x"', 'wait Infinity']) assert.throws(() => parseScript(source), /Line 1/);
  assert.throws(() => parseScript('# empty\n'), /no commands/);
});
test('every supported command round-trips without losing arguments', () => {
  const source = 'tap 1 2\ntype "field" "text"\nswipe 1 2 3 4 500\nkey home\nlaunch "a.b"\nstop "a.b"\ninstall "/a.apk"\nscreenshot "capture"\nwait 100\nwait_for "Hello" 500\nassert "OK"\nassert_not "Error"\nextract value "Hello"\nrun "a.mob"\nrecord_start\nrecord_stop "clip"\nmeasure_perf "a.b"\nassert_perf memory_mb < 200\nassert_baseline "home" 0.1';
  const parsed = parseScript(source); assert.deepEqual(parseScript(toScript(parsed)), parsed);
});
test('artifact and test paths stay inside their directory', () => {
  for (const name of ['../secret', '..', '/etc/passwd', 'a/b', 'a\\b', 'x\nheader', '.hidden', 'a..b']) assert.throws(() => safeName(name));
  assert.equal(safeName('login-flow.mob'), 'login-flow.mob');
});
test('ADB shell arguments do not execute device shell substitutions', () => {
  assert.equal(shellQuote("a'b; $(id) `id`"), "'a'\\''b; $(id) `id`'");
});
test('Android and iOS trees yield visible elements and exact selectors win', () => {
  const android = parseElements('<hierarchy><node text="Sign in" resource-id="app:id/login" class="Button" bounds="[0,100][200,150]" enabled="true"/><node text="Sign in later" bounds="[0,200][200,250]"/></hierarchy>');
  assert.equal(findElement(android, 'Sign in').id, 'app:id/login');
  assert.equal(findElement(android, 'app:id/login').bounds.y, 100);
  assert.throws(() => findElement(android, 'Sign'), /Ambiguous/);
  const ios = parseElements('<AppiumAUT><XCUIElementTypeButton name="go" label="Continue" x="10" y="20" width="100" height="40" visible="true" enabled="true"/><XCUIElementTypeButton name="hidden" x="0" y="0" width="100" height="40" visible="false"/></AppiumAUT>');
  assert.equal(ios.length, 1); assert.equal(findElement(ios, 'Continue').bounds.width, 100);
  const disabled = { ...ios[0]!, enabled: false };
  assert.equal(findElement([disabled], 'Continue').enabled, false);
  assert.throws(() => findElement([disabled], 'Continue', true), /Element not found/);
});
