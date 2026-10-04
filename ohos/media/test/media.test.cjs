const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const devEco = process.env.DEVECO_STUDIO_HOME || '/Applications/DevEco-Studio.app/Contents';
const ts = require(path.join(devEco, 'tools/hvigor/hvigor/node_modules/typescript'));
const source = fs.readFileSync(path.join(__dirname, '../src/main/ets/MediaModule.ets'), 'utf8');
const compiled = ts.transpileModule(source, {
  compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020 }
}).outputText;
const MAX_BYTES = 32 * 1024 * 1024;
const deferred = () => {
  let resolve, reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
};
const flush = async () => { for (let i = 0; i < 40; i++) await Promise.resolve(); };

function fixture(options = {}) {
  const events = { selected: 0, opened: [], closed: [], written: [], removed: [], decoded: 0,
    encoded: [], sources: 0, sourceReleased: 0, pixelsReleased: 0, packerReleased: 0, helperReleased: 0 };
  const exports = {};
  let nextFd = 1;
  const files = new Map();
  class BaseModule { constructor() { this.controller = { getUIAbilityContext: () => ({ cacheDir: '/cache' }) }; } onDestroy() {} }
  const sourceFor = bytes => {
    events.sources++;
    return {
      getImageInfo: async () => ({ mimeType: 'image/png', size: { width: 100, height: 100 } }),
      createPixelMap: async () => ({ release: async () => { events.pixelsReleased++; } }),
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
      write: async (fd, bytes) => { events.written.push(files.get(fd)); return bytes.byteLength; },
      unlink: async value => { events.removed.push(value); }
    } },
    '@kit.ArkTS': { util: { Base64Helper: class {
      decodeSync(value) { events.decoded++; return Uint8Array.from(Buffer.from(value, 'base64')); }
      encodeToStringSync(bytes) { events.encoded.push(bytes); return 'BwcH'; }
    } } },
    '@kit.BasicServicesKit': {}
  };
  vm.runInNewContext(compiled, { exports, require: name => {
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
