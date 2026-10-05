const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const devEco = process.env.DEVECO_STUDIO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(process.env.TYPESCRIPT_PATH || path.join(devEco, 'tools/hvigor/hvigor/node_modules/typescript'));
const source = fs.readFileSync(path.join(__dirname, '../src/main/ets/MediaModule.ets'), 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
const MAX_BYTES = 32 * 1024 * 1024;
let nextIdentifier = 0;
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};
// 让本轮异步 I/O 链排空，避免部分读写增加 await 数量后超过固定微任务预算。
const flush = () => new Promise(resolve => setImmediate(resolve));

function fixture(options = {}) {
  const events = { selected: 0, opened: [], closed: [], written: [], removed: [], decoded: 0,
    encoded: [], writes: [], sources: 0, pixelDecodes: 0, sourceReleased: 0, pixelsReleased: 0, packerReleased: 0, helperReleased: 0 };
  const exports = {};
  let nextFd = 1;
  const files = new Map();
  class BaseModule { constructor() { this.controller = { getUIAbilityContext: () => ({ cacheDir: '/cache' }) }; } onDestroy() {} }
  const sourceFor = bytes => {
    events.sources++;
    return {
      getImageInfo: async () => ({ mimeType: 'image/png', size: { width: 100, height: 100 } }),
      createPixelMap: async settings => {
        events.pixelDecodes++;
        if (options.decodePixels) await options.decodePixels(settings);
        return { release: async () => { events.pixelsReleased++; } };
      },
      release: async () => { events.sourceReleased++; }
    };
  };
  const mocks = {
    '@kuikly-open/render': { KuiklyRenderBaseModule: BaseModule },
    '@kit.CameraKit': { camera: { CameraPosition: { CAMERA_POSITION_BACK: 0 } }, cameraPicker: {
      PickerMediaType: { PHOTO: 0 }, pick: options.capture || (async () => ({ resultCode: 0, resultUri: 'camera' }))
    } },
    '@kit.MediaLibraryKit': { photoAccessHelper: {
      PhotoViewPicker: class { select() { events.selected++; return options.select?.() || Promise.resolve({ photoUris: ['image'] }); } },
      PhotoViewMIMETypes: { IMAGE_TYPE: 0 }, PhotoType: { IMAGE: 0 },
      getPhotoAccessHelper: () => ({
        showAssetsCreationDialog: options.dialog || (async () => ['file://destination']),
        release: async () => { events.helperReleased++; }
      })
    } },
    '@kit.ImageKit': { image: { createImageSource: sourceFor, createImagePacker: () => ({
      packing: options.packing || (async () => new ArrayBuffer(3)),
      release: async () => { events.packerReleased++; }
    }) } },
    '@kit.CoreFileKit': { fileUri: { getUriFromPath: value => `file://${value}` }, fileIo: {
      OpenMode: { CREATE: 1, READ_WRITE: 2, READ_ONLY: 4, WRITE_ONLY: 8, TRUNC: 16 },
      open: async uri => { const fd = nextFd++; files.set(fd, uri); events.opened.push(uri); return { fd }; },
      close: async file => { events.closed.push(typeof file === 'number' ? file : file.fd); },
      stat: async fd => ({ size: options.size?.(files.get(fd)) || 3 }),
      read: async (fd, buffer) => {
        if (options.read) return options.read(fd, buffer);
        new Uint8Array(buffer).fill(7); return buffer.byteLength;
      },
      write: async (fd, bytes) => { events.written.push(files.get(fd)); events.writes.push(Array.from(new Uint8Array(bytes))); return options.write ? options.write(files.get(fd), bytes) : bytes.byteLength; },
      unlink: async value => { events.removed.push(value); }
    } },
    '@kit.ArkTS': { util: { generateRandomUUID: () => `instance-${++nextIdentifier}`, Base64Helper: class {
      decodeSync(value) { events.decoded++; return Uint8Array.from(Buffer.from(value, 'base64')); }
      encodeToStringSync(bytes) { events.encoded.push(bytes); return 'BwcH'; }
    } } },
    '@kit.BasicServicesKit': {}
  };
  vm.runInNewContext(compiled, { exports, Date: class extends Date { static now() { return 1000; } }, require: name => {
    assert.ok(mocks[name], `unexpected import ${name}`); return mocks[name];
  } });
  return { module: new exports.MediaModule(), events };
}
function invoke(module, method, args) {
  const responses = [];
  module.call(method, JSON.stringify(args), value => responses.push(value));
  return responses;
}
function cancel(module, requestId) { module.call('cancel', JSON.stringify({ requestId }), null); }
const pick = requestId => ({ requestId, source: 'GALLERY', maxCount: 1, maxDimension: 0, jpegQuality: 0 });

test('two Module instances at the same millisecond own different temporary files', async () => {
  const first = fixture(), second = fixture();
  const a = invoke(first.module, 'save', { requestId: 'a', data: 'BwcH' });
  const b = invoke(second.module, 'save', { requestId: 'b', data: 'BwcH' });
  await flush();
  assert.equal(a[0].status, 'saved');
  assert.equal(b[0].status, 'saved');
  assert.notEqual(first.events.removed[0], second.events.removed[0]);
  assert.ok(first.events.removed[0].startsWith('/cache/media_instance-'));
});

test('uncompressed selection keeps original bytes and releases native handles', async () => {
  const { module, events } = fixture();
  const responses = invoke(module, 'pick', pick('original'));
  await flush();
  assert.equal(responses[0].status, 'selected');
  assert.equal(responses[0].images[0].contentType, 'image/png');
  assert.deepEqual(Array.from(events.encoded[0]), [7, 7, 7]);
  assert.equal(events.sourceReleased, 1);
  assert.equal(events.pixelsReleased, 0);
  assert.equal(events.closed.length, 1);
});

test('cancel resolves only its request; old system Picker stays busy until it returns', async () => {
  const oldPicker = deferred(), newestPicker = deferred();
  let selections = 0;
  const { module, events } = fixture({ select: () => (++selections === 1 ? oldPicker.promise : newestPicker.promise) });
  const old = invoke(module, 'pick', pick('old'));
  cancel(module, 'old');
  await flush();
  assert.equal(old[0].status, 'cancelled');
  const busy = invoke(module, 'pick', pick('busy'));
  await flush();
  assert.equal(busy[0].status, 'busy');
  assert.equal(events.selected, 1);
  oldPicker.resolve({ photoUris: ['late-old'] });
  await flush();
  assert.equal(events.opened.length, 0);
  const newest = invoke(module, 'pick', pick('newest'));
  cancel(module, 'old');
  await flush();
  assert.equal(newest.length, 0);
  newestPicker.resolve({ photoUris: [] });
  await flush();
  assert.equal(newest[0].status, 'cancelled');
  assert.equal(old.length, 1);
});

test('save cancellation prevents target write and releases helper and temporary file', async () => {
  const dialog = deferred();
  const { module, events } = fixture({ dialog: () => dialog.promise });
  const responses = invoke(module, 'save', { requestId: 'save', data: 'BwcH', fileNamePrefix: 'test' });
  await flush();
  cancel(module, 'save');
  await flush();
  assert.equal(responses[0].status, 'cancelled');
  dialog.resolve(['file://destination']);
  await flush();
  assert.ok(events.written.every(uri => uri.startsWith('/cache/')));
  assert.equal(events.helperReleased, 1);
  assert.equal(events.removed.length, 1);
  assert.equal(events.closed.length, 1);
  assert.equal(responses.length, 1);
});

test('destroy cancels owned waiting and prevents late reads and callbacks', async () => {
  const picker = deferred();
  const { module, events } = fixture({ select: () => picker.promise });
  const responses = invoke(module, 'pick', pick('destroyed'));
  module.onDestroy();
  await flush();
  picker.resolve({ photoUris: ['late'] });
  await flush();
  assert.equal(responses.length, 0);
  assert.equal(events.opened.length, 0);
  assert.equal(module.requests.size, 0);
});

test('cancel during file read stops decoding and closes the owned descriptor', async () => {
  const reading = deferred();
  const { module, events } = fixture({ read: () => reading.promise });
  const responses = invoke(module, 'pick', pick('reading'));
  await flush();
  cancel(module, 'reading');
  await flush();
  assert.equal(responses[0].status, 'cancelled');
  reading.resolve(3);
  await flush();
  assert.equal(events.closed.length, 1);
  assert.equal(events.sources, 0);
});

test('Base64 bounds reject oversize data before allocating decoded bytes', async () => {
  const { module, events } = fixture();
  const maxEncoded = Math.ceil(MAX_BYTES / 3) * 4;
  const oversized = invoke(module, 'save', { requestId: 'oversized', data: 'A'.repeat(maxEncoded + 4) });
  const paddedBoundary = invoke(module, 'save', { requestId: 'no-padding', data: 'A'.repeat(maxEncoded) });
  await flush();
  assert.equal(oversized[0].status, 'invalid_content');
  assert.equal(paddedBoundary[0].status, 'invalid_content');
  assert.equal(events.decoded, 0);
});

test('aggregate original bound rejects next image before allocating or image decoding', async () => {
  const { module, events } = fixture({ select: async () => ({ photoUris: ['first', 'second'] }), size: () => MAX_BYTES / 2 + 1 });
  const responses = invoke(module, 'pick', { ...pick('aggregate'), maxCount: 2 });
  await flush();
  assert.equal(responses[0].status, 'failed');
  assert.equal(events.sources, 1);
  assert.equal(events.closed.length, 2);
});

test('oversized JPEG packing never encodes Base64 and releases all native image objects', async () => {
  const { module, events } = fixture({ packing: async () => new ArrayBuffer(MAX_BYTES + 1) });
  const responses = invoke(module, 'pick', { ...pick('jpeg'), maxDimension: 64, jpegQuality: 85 });
  await flush();
  assert.equal(responses[0].status, 'failed');
  assert.equal(events.encoded.length, 0);
  assert.equal(events.sourceReleased, 1);
  assert.equal(events.pixelsReleased, 1);
  assert.equal(events.packerReleased, 1);
});

test('packing failure also releases source pixel map and packer', async () => {
  const { module, events } = fixture({ packing: async () => { throw new Error('packing failed'); } });
  const responses = invoke(module, 'pick', { ...pick('broken-jpeg'), maxDimension: 64, jpegQuality: 85 });
  await flush();
  assert.equal(responses[0].status, 'failed');
  assert.equal(events.sourceReleased, 1);
  assert.equal(events.pixelsReleased, 1);
  assert.equal(events.packerReleased, 1);
});

test('cancelling one concurrent save cannot cancel or deliver the other save result', async () => {
  const firstDialog = deferred(), secondDialog = deferred();
  let count = 0;
  const { module, events } = fixture({ dialog: () => (++count === 1 ? firstDialog.promise : secondDialog.promise) });
  const first = invoke(module, 'save', { requestId: 'save-first', data: 'BwcH' });
  const second = invoke(module, 'save', { requestId: 'save-second', data: 'BwcH' });
  await flush();
  cancel(module, 'save-first');
  await flush();
  assert.equal(first[0].status, 'cancelled');
  assert.equal(second.length, 0);
  secondDialog.resolve(['file://second-destination']);
  await flush();
  assert.equal(second[0].status, 'saved');
  firstDialog.resolve(['file://first-destination']);
  await flush();
  assert.ok(!events.written.includes('file://first-destination'));
  assert.ok(events.written.includes('file://second-destination'));
  assert.equal(first.length, 1);
  assert.equal(second.length, 1);
  assert.equal(events.helperReleased, 2);
});

test('camera cancellation removes only its temporary file when system capture finishes', async () => {
  const capture = deferred();
  const { module, events } = fixture({ capture: () => capture.promise });
  const responses = invoke(module, 'pick', { ...pick('camera-cancel'), source: 'CAMERA' });
  await flush();
  cancel(module, 'camera-cancel');
  await flush();
  assert.equal(responses[0].status, 'cancelled');
  capture.resolve({ resultCode: 0, resultUri: 'late-camera' });
  await flush();
  assert.equal(events.opened.length, 1);
  assert.equal(events.closed.length, 1);
  assert.equal(events.removed.length, 1);
  assert.equal(events.sources, 0);
  assert.equal(responses.length, 1);
});


test('partial reads and writes preserve every byte and close both save descriptors', async () => {
  const reading = fixture({ read: (_fd, buffer) => { new Uint8Array(buffer)[0] = 7; return 1; } });
  const picked = invoke(reading.module, 'pick', pick('partial-read'));
  await flush();
  assert.equal(picked[0].status, 'selected');
  assert.deepEqual(Array.from(reading.events.encoded[0]), [7, 7, 7]);
  assert.equal(reading.events.closed.length, 1);
  const saving = fixture({ write: (_uri, bytes) => Math.min(1, bytes.byteLength) });
  const saved = invoke(saving.module, 'save', { requestId: 'partial-write', data: 'AQID' });
  await flush();
  assert.equal(saved[0].status, 'saved');
  assert.deepEqual(saving.events.writes, [[1, 2, 3], [2, 3], [3], [1, 2, 3], [2, 3], [3]]);
  assert.equal(saving.events.closed.length, 2);
  assert.equal(saving.events.helperReleased, 1);
  assert.equal(saving.events.removed.length, 1);
});

test('zero target write and rejected authorization never report saved and still release resources', async () => {
  const failure = fixture({ write: uri => uri.startsWith('file://') ? 0 : 3 });
  const responses = invoke(failure.module, 'save', { requestId: 'target-error', data: 'AQID' });
  await flush();
  assert.equal(responses[0].status, 'failed');
  assert.equal(failure.events.closed.length, 2);
  assert.equal(failure.events.helperReleased, 1);
  assert.equal(failure.events.removed.length, 1);
  const denied = fixture({ dialog: async () => { throw { code: 201 }; } });
  const deniedResponses = invoke(denied.module, 'save', { requestId: 'denied', data: 'AQID' });
  await flush();
  assert.equal(deniedResponses[0].status, 'permission_denied');
  assert.equal(denied.events.closed.length, 1);
  assert.equal(denied.events.helperReleased, 1);
  assert.equal(denied.events.removed.length, 1);
});

test('camera failure does not masquerade as cancellation and removes its owned temporary file', async () => {
  const { module, events } = fixture({ capture: async () => ({ resultCode: -1, resultUri: '' }) });
  const responses = invoke(module, 'pick', { ...pick('capture-failed'), source: 'CAMERA' });
  await flush();
  assert.equal(responses[0].status, 'failed');
  assert.equal(events.opened.length, 1);
  assert.equal(events.closed.length, 1);
  assert.equal(events.removed.length, 1);
});

test('malformed save prefix is rejected before decoding or native writes', async () => {
  const { module, events } = fixture();
  let result;
  module.call('save', JSON.stringify({ requestId: 'bad-prefix', data: 'AQ==', fileNamePrefix: 3 }), value => { result = value; });
  await flush();
  assert.equal(result.status, 'invalid_content');
  assert.equal(events.decoded, 0);
  assert.equal(events.sources, 0);
  assert.deepEqual(events.opened, []);
});

test('save rejects metadata-only image when pixel decoding fails before any file or authorization', async () => {
  const { module, events } = fixture({ decodePixels: async () => { throw new Error('Incomplete pixels'); } });
  const responses = invoke(module, 'save', { requestId: 'bad-pixels', data: 'AQID' });
  await flush();
  assert.equal(responses[0].status, 'invalid_content');
  assert.equal(events.pixelDecodes, 1);
  assert.equal(events.sourceReleased, 1);
  assert.equal(events.helperReleased, 0);
  assert.deepEqual(events.opened, []);
});

test('cancellation during save pixel decoding releases decoded resources without opening a file', async () => {
  const pixels = deferred();
  const { module, events } = fixture({ decodePixels: () => pixels.promise });
  const responses = invoke(module, 'save', { requestId: 'pixel-cancel', data: 'AQID' });
  await flush();
  cancel(module, 'pixel-cancel');
  pixels.resolve();
  await flush();
  assert.equal(responses[0].status, 'cancelled');
  assert.equal(responses.length, 1);
  assert.equal(events.sourceReleased, 1);
  assert.equal(events.pixelsReleased, 1);
  assert.deepEqual(events.opened, []);
});

test('save rejects PNG with dimensions but missing pixel payload/end even if native decoder tolerates it', async () => {
  // 真实 2x2 PNG，截到 IDAT type。元数据/像素 mock 都可成功，边界仍必须在系统授权前拒绝。
  const png = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFElEQVQImWP8z8Dwn4GBgYGJAQoAHgQCAfQ/XjoAAAAASUVORK5CYII=', 'base64');
  const truncated = png.subarray(0, png.indexOf('IDAT') + 4);
  const rejected = fixture();
  const responses = invoke(rejected.module, 'save', { requestId: 'partial-png', data: truncated.toString('base64') });
  await flush();
  assert.equal(responses[0].status, 'invalid_content');
  assert.equal(rejected.events.sources, 0);
  assert.deepEqual(rejected.events.opened, []);
  const valid = fixture();
  const original = Buffer.concat([png, Buffer.from([0, 32])]);
  const saved = invoke(valid.module, 'save', { requestId: 'complete-png', data: original.toString('base64') });
  await flush();
  assert.equal(saved[0].status, 'saved');
  assert.equal(valid.events.pixelsReleased, 1);
  assert.deepEqual(valid.events.writes[1], [...original]);
});

test('JPEG metadata embedded EOI cannot replace primary end marker', async () => {
  const truncated = fixture();
  const bytes = Buffer.from([255, 216, 255, 225, 0, 4, 255, 217, 255, 218, 0, 2, 1, 2]);
  const responses = invoke(truncated.module, 'save', { requestId: 'embedded-end', data: bytes.toString('base64') });
  await flush();
  assert.equal(responses[0].status, 'invalid_content');
  assert.equal(truncated.events.sources, 0);
  const complete = fixture();
  const saved = invoke(complete.module, 'save', { requestId: 'primary-end', data: Buffer.concat([bytes, Buffer.from([255, 217, 0, 32])]).toString('base64') });
  await flush();
  assert.equal(saved[0].status, 'saved');
});
