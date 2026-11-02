const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require(process.env.TYPESCRIPT_PATH || '/Applications/DevEco-Studio.app/Contents/tools/hvigor/hvigor/node_modules/typescript');
const source = fs.readFileSync(path.join(__dirname, '../src/main/ets/MediaFilePicker.ets'), 'utf8');

function fixture(config = {}) {
  const events = [], exports = {};
  let resolveSelection, rejectSelection;
  const selection = new Promise((resolve, reject) => { resolveSelection = resolve; rejectSelection = reject; });
  const descriptor = { UniformDataType: { IMAGE: 'image', VIDEO: 'video' },
    getUniformDataTypeByFilenameExtension: value => { if (value === '.unknown') throw Error('unknown'); return value; },
    getUniformDataTypeByMIMEType: value => value,
    getTypeDescriptor: value => { const type = { '.jpg': 'image/jpeg', '.mp4': 'video/mp4', '.tga': 'image/x-tga', 'image/jpeg': 'image/jpeg' }[value] || '';
      return { mimeTypes: type ? [type] : [], belongsTo: kind => type.startsWith(kind + '/') }; } };
  const mocks = {
    '@kit.PerformanceAnalysisKit': { hilog: { debug: (...args) => events.push(['trace', ...args]) } },
    '@kit.ArkData': { uniformTypeDescriptor: descriptor },
    '@kit.CoreFileKit': { picker: { DocumentSelectOptions: class {}, DocumentViewPicker: class { select(options) { events.push(['document', options]); return selection; } } },
      fileUri: { FileUri: class { constructor(uri) { this.name = uri.split('/').at(-1); } }, getUriFromPath: path => `file://${path}` },
      fileIo: { OpenMode: { READ_ONLY: 0, CREATE: 1, READ_WRITE: 2 }, WhenceType: { SEEK_SET: 0 }, lseek: (fd, offset, whence) => { events.push(['seek', fd, offset, whence]); return 0; }, openSync: uri => ({ fd: uri }), closeSync() {}, statSync: () => ({ size: config.size ?? 16 }), unlinkSync: path => events.push(['unlink', path]),
        open: async uri => { events.push(['open', uri]); if (config.waitOpen) await config.waitOpen; return { fd: uri }; },
        close: async file => { events.push(['close', file.fd]); },
        stat: async fd => { events.push(['stat', fd]); if (config.waitStat) await config.waitStat; return { size: config.size ?? 16 }; },
        read: async (fd, buffer) => { const bytes = new Uint8Array(buffer); if (String(fd).startsWith('/cache/')) bytes.set([0xff, 0xd8, 0xff]); else bytes.fill(7); return buffer.byteLength; } } },
    '@kit.MediaLibraryKit': { photoAccessHelper: { PhotoViewMIMETypes: { IMAGE_TYPE: 'image/*', VIDEO_TYPE: 'video/*', IMAGE_VIDEO_TYPE: '*/*' },
      PhotoViewPicker: class { select(options) { events.push(['photo', options]); return selection; } } } },
    '@kit.AbilityKit': {}, '@kit.CameraKit': { camera: { CameraPosition: { CAMERA_POSITION_BACK: 1 } }, cameraPicker: { PickerMediaType: { PHOTO: 'photo', VIDEO: 'video' }, pick: async () => config.cameraResult } },
    '@kit.ImageKit': { image: { createImageSource: fd => { events.push(['image-source', fd]); return { getImageInfo: async () => ({ mimeType: config.imageMime || 'image/png', size: { width: 1, height: 1 } }), release: async () => { events.push(['image-release', fd]); } }; } } },
    '@kit.MediaKit': { media: { createAVMetadataExtractor: async () => { events.push(['video-source']); return {
      fetchMetadata: async () => { if (config.waitMetadata) await config.waitMetadata; if (config.videoError) throw Error('metadata unavailable'); return { mimeType: config.videoMime || 'video/mp4' }; },
      release: async () => { events.push(['video-release']); },
    }; } } },
    '@kit.ArkTS': { util: { generateRandomUUID: () => 'unit', Base64Helper: class { encodeToStringSync(bytes) { return Buffer.from(bytes).toString('base64'); } } } },
  };
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText,
    { exports, require: name => mocks[name], setTimeout, Promise, Set, Map });
  return { picker: new exports.MediaFilePicker(), MediaFilePicker: exports.MediaFilePicker, mocks, events, resolveSelection, rejectSelection };
}
const tick = () => new Promise(resolve => setTimeout(resolve, 10));
const request = accepts => ({ context: {}, uiContext: {}, acceptTypes: accepts, multiple: false, capture: false, captureEnabled: false,
  valid: () => true, visible: () => true, waitVisible: async () => {}, authorizeCapture: async () => true });

test('raw media and document selection routes and validates metadata', async () => {
  for (const [accepts, kind, mode, name, status] of [
    [['image/*'], 'photo', 'image/*', 'photo.jpg', 'selected'],
    [['video/*'], 'photo', 'video/*', 'movie.mp4', 'selected'],
    [['image/*', 'video/*'], 'photo', '*/*', 'photo.jpg', 'selected'],
    [['*/*'], 'document', null, 'LICENSE', 'selected'],
    [['.unknown'], 'document', null, 'file.unknown', 'selected'],
    [['.license'], 'document', null, 'LICENSE', 'failed'],
    [['image/*', '.unknown'], 'document', null, 'file.unknown', 'selected'],
  ]) {
    const f = fixture(), results = [];
    f.picker.select(request(accepts), result => results.push(JSON.parse(JSON.stringify(result))));
    const call = f.events.find(event => event[0] === kind); assert.ok(call); assert.equal(call[1].maxSelectNumber, 1);
    const trace = f.events.find(event => event[0] === 'trace');
    assert.equal(trace[2], 'GycMediaPicker');
    assert.equal(trace[4], kind === 'document' ? 'documents' : mode === '*/*' ? 'mixed' : mode === 'video/*' ? 'videos' : 'photos');
    assert.equal(trace[5], 1); assert.equal(trace[6], 'false'); assert.equal(trace.length, 7);
    if (mode) assert.equal(call[1].MIMEType, mode);
    const uri = `file://selected/${name}`;
    f.resolveSelection(kind === 'photo' ? { photoUris: [uri] } : [uri]); await tick();
    assert.equal(results[0].status, status);
    if (status === 'selected') {
      assert.equal(results[0].files[0].uri, uri); assert.equal(results[0].files[0].size, 16);
      for (const operation of ['open', 'stat', 'close']) assert.equal(f.events.filter(event => event[0] === operation && event[1] === uri).length, 1, operation);
    }
    f.picker.revoke();
  }
});

test('expanded Chromium media wildcards route to gallery and aliases match selected files', async () => {
  const imageTypes = ['.apng', '.avif', '.bmp', '.gif', '.ico', '.jpe', '.jfif', '.jpeg', '.jpg', '.jxl', '.pjp', '.pjpeg', '.png', '.svg', '.svgz', '.tif', '.tiff', '.webp', '.xbm'];
  const videoTypes = ['.mp4', '.m4v', '.mp4v', '.mpg4', '.mov', '.qt', '.webm', '.ogv', '.ogm', '.mpeg', '.mpg', '.mpe', '.m1v', '.m2v'];
  for (const [accepts, mode, uri, expected] of [
    [imageTypes, 'image/*', 'file://selected/photo.jpg', 'selected'],
    [videoTypes, 'video/*', 'file://selected/movie.mp4', 'selected'],
    [[...imageTypes, ...videoTypes], '*/*', 'file://selected/photo.jpg', 'selected'],
    [['.jfif'], 'image/*', 'file://selected/photo.jpg', 'selected'],
    [['.pjpeg'], 'image/*', 'file://selected/photo.jpg', 'selected'],
    [['.apng'], 'image/*', 'file://selected/photo.apng', 'selected'],
    [['.jxl'], 'image/*', 'file://selected/photo.jxl', 'selected'],
    [['.pjp'], 'image/*', 'file://selected/photo.png', 'failed'],
    [['video/mov'], 'video/*', 'file://selected/movie.mov', 'selected'],
    [['image/future-format'], 'image/*', 'file://selected/photo.jpg', 'failed'],
    [['video/future-format'], 'video/*', 'file://selected/movie.mp4', 'failed'],
    [['.tga'], 'image/*', 'file://selected/photo.tga', 'selected'],
    [['image/gif', 'image/jpeg', 'image/jpg', 'image/png', 'image/bmp', 'image/webp', 'video/mov', 'video/mp4'], '*/*', 'file://selected/movie.mov', 'selected'],
  ]) {
    const f = fixture(), results = [];
    f.picker.select(request(accepts), result => results.push(result.status));
    const call = f.events.find(event => event[0] === 'photo'); assert.ok(call); assert.equal(call[1].MIMEType, mode);
    f.resolveSelection({ photoUris: [uri] }); await tick(); assert.deepEqual(results, [expected]); f.picker.revoke();
  }
  for (const other of ['.unknown', '.pdf']) {
    const f = fixture(), results = [];
    f.picker.select(request([...imageTypes, other]), result => results.push(result.status));
    assert.ok(f.events.some(event => event[0] === 'document')); f.resolveSelection([]); await tick();
    assert.deepEqual(results, ['cancelled']); f.picker.revoke();
  }
  {
    const f = fixture(), results = [];
    f.picker.select(request(['*']), result => results.push(result.status));
    assert.ok(f.events.some(event => event[0] === 'document')); f.resolveSelection(['file://selected/LICENSE']); await tick();
    assert.deepEqual(results, ['selected']); f.picker.revoke();
  }
});

test('successful camera result without URI remains cancellation and releases temporary output', async () => {
  const f = fixture({ cameraResult: { resultCode: 0, resultUri: '' } }), results = [];
  f.picker.select({ ...request(['image/jpeg']), context: { cacheDir: '/cache' }, capture: true, captureEnabled: true }, result => results.push(result.status));
  await tick(); assert.deepEqual(results, ['cancelled']);
  const trace = f.events.find(event => event[0] === 'trace');
  assert.equal(trace[4], 'camera-photo'); assert.equal(trace[5], 1); assert.equal(trace[6], 'true');
  assert.equal(f.events.filter(event => event[0] === 'unlink').length, 1); f.picker.revoke();
});

test('captured result is checked and returned with one read-only open/stat/close', async () => {
  const path = '/cache/gy-media-unit.jpg';
  const f = fixture({ cameraResult: { resultCode: 0, resultUri: `file://${path}`, mediaType: 'photo' } }), results = [];
  f.picker.select({ ...request(['image/jpeg']), context: { cacheDir: '/cache' }, capture: true, captureEnabled: true }, result => results.push(result.status));
  await tick(); assert.deepEqual(results, ['selected']);
  for (const operation of ['open', 'stat', 'close']) assert.equal(f.events.filter(event => event[0] === operation && event[1] === path).length, 1, operation);
  f.picker.revoke();
});

test('revocation during metadata IO closes the descriptor and suppresses late delivery', async () => {
  let finishStat; const waitStat = new Promise(resolve => { finishStat = resolve; });
  let active = true; const f = fixture({ waitStat }), results = [];
  f.picker.select({ ...request(['image/*']), multiple: true, valid: () => active }, result => results.push(result.status));
  const first = 'file://selected/a.jpg';
  f.resolveSelection({ photoUris: [first, 'file://selected/b.jpg'] }); await tick();
  assert.equal(f.events.filter(event => event[0] === 'open').length, 1);
  active = false; f.picker.revoke(); finishStat(); await tick();
  assert.deepEqual(results, ['cancelled']);
  for (const operation of ['open', 'stat', 'close']) assert.equal(f.events.filter(event => event[0] === operation && event[1] === first).length, 1, operation);
  assert.equal(f.events.filter(event => event[0] === 'open').length, 1, 'no later file is opened');
});

test('revocation during open closes without metadata or content access', async () => {
  let finishOpen; const waitOpen = new Promise(resolve => { finishOpen = resolve; });
  let active = true; const f = fixture({ waitOpen }), results = [];
  f.picker.select({ ...request(['image/*']), valid: () => active }, result => results.push(result.status));
  f.resolveSelection({ photoUris: ['file://selected/a.jpg'] }); await tick();
  active = false; f.picker.revoke(); finishOpen(); await tick();
  assert.deepEqual(results, ['cancelled']);
  assert.equal(f.events.filter(event => event[0] === 'close').length, 1);
  assert.equal(f.events.filter(event => event[0] === 'stat').length, 0);
});

test('extensionless media uses decoder MIME on the same selected descriptor', async () => {
  for (const [accept, expected] of [['image/png', 'selected'], ['image/jpeg', 'failed'], ['video/mp4', 'selected'], ['video/webm', 'failed']]) {
    const f = fixture(), results = [], uri = 'file://media/no-extension';
    f.picker.select(request([accept]), result => results.push(JSON.parse(JSON.stringify(result))));
    f.resolveSelection({ photoUris: [uri] }); await tick();
    assert.equal(results[0].status, expected);
    for (const operation of ['open', 'stat', 'close']) assert.equal(f.events.filter(event => event[0] === operation && event[1] === uri).length, 1, operation);
    assert.equal(f.events.filter(event => event[0] === 'image-source').length, accept.startsWith('image/') ? 1 : 0);
    assert.equal(f.events.filter(event => event[0] === 'image-release').length, accept.startsWith('image/') ? 1 : 0);
    assert.equal(f.events.filter(event => event[0] === 'video-release').length, accept.startsWith('video/') ? 1 : 0);
    if (expected === 'selected') assert.equal(results[0].files[0].mimeType, accept);
    f.picker.revoke();
  }
});

test('extensionless video cannot be inferred from requested family and generic files avoid decoding', async () => {
  for (const [accept, videoMime, expected, sourceCount] of [['video/mp4', 'audio/mp4', 'failed', 1], ['*/*', 'video/mp4', 'selected', 0]]) {
    const f = fixture({ videoMime }), results = [];
    f.picker.select(request([accept]), result => results.push(result.status));
    f.resolveSelection(accept === '*/*' ? ['file://picked/no-extension'] : { photoUris: ['file://picked/no-extension'] });
    await tick(); assert.deepEqual(results, [expected]);
    assert.equal(f.events.filter(event => event[0] === 'video-source').length, sourceCount);
    assert.equal(f.events.filter(event => event[0] === 'image-source').length, 0); f.picker.revoke();
  }
});

test('video metadata failure releases extractor and selected descriptor', async () => {
  const f = fixture({ videoError: true }), results = [], uri = 'file://selected/no-extension';
  f.picker.select(request(['video/mp4']), result => results.push(result.status));
  f.resolveSelection({ photoUris: [uri] }); await tick();
  assert.deepEqual(results, ['failed']);
  assert.equal(f.events.filter(event => event[0] === 'video-release').length, 1);
  for (const operation of ['open', 'stat', 'close']) assert.equal(f.events.filter(event => event[0] === operation && event[1] === uri).length, 1, operation);
  const released = f.events.findIndex(event => event[0] === 'video-release');
  const closed = f.events.findIndex(event => event[0] === 'close'); assert.ok(released < closed);
  f.picker.revoke();
});

test('late video metadata is never delivered after owner revocation', async () => {
  let finish; const waitMetadata = new Promise(resolve => { finish = resolve; });
  let active = true; const f = fixture({ waitMetadata }), results = [];
  f.picker.select({ ...request(['video/mp4']), valid: () => active }, result => results.push(result.status));
  f.resolveSelection({ photoUris: ['file://selected/no-extension'] }); await tick();
  active = false; f.picker.revoke(); finish(); await tick();
  assert.deepEqual(results, ['cancelled']);
  assert.equal(f.events.filter(event => event[0] === 'video-release').length, 1);
  assert.equal(f.events.filter(event => event[0] === 'close').length, 1);
});

test('legacy module calls the actual raw picker and preserves original bytes', async () => {
  const f = fixture(), output = {};
  f.mocks['./MediaFilePicker'] = { MediaFilePicker: f.MediaFilePicker };
  f.mocks['@kuikly-open/render'] = { KuiklyRenderBaseModule: class { constructor() { this.controller = { getUIAbilityContext: () => ({ cacheDir: '/cache' }) }; } } };
  f.mocks['@kit.BasicServicesKit'] = {};
  const moduleSource = fs.readFileSync(path.join(__dirname, '../src/main/ets/MediaModule.ets'), 'utf8');
  vm.runInNewContext(ts.transpileModule(moduleSource, { compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS } }).outputText,
    { exports: output, require: name => f.mocks[name], Promise, Map, Date });
  const responses = [];
  new output.MediaModule().call('pick', JSON.stringify({ requestId: 'one', source: 'GALLERY', maxCount: 1 }), value => responses.push(value));
  assert.ok(f.events.some(event => event[0] === 'photo'));
  f.resolveSelection({ photoUris: ['file://media/image.jpg'] }); await tick(); await tick();
  assert.equal(responses[0].status, 'selected'); assert.equal(responses[0].images[0].data, Buffer.alloc(16, 7).toString('base64'));
  for (const operation of ['open', 'stat', 'close']) assert.equal(f.events.filter(event => event[0] === operation && event[1] === 'file://media/image.jpg').length, 2, `${operation}: one raw validation plus one legacy byte read`);
});

test('legacy raw requests preserve 500 count, 32 MiB and permission classification', async () => {
  {
    const f = fixture(), results = [];
    f.picker.select({ ...request(['image/*']), multiple: true, maxFiles: 500, maxBytes: 32 * 1024 * 1024,
      validateMime: false, uiContext: null }, result => results.push(result.status));
    assert.equal(f.events.find(event => event[0] === 'photo')[1].maxSelectNumber, 500);
    f.resolveSelection({ photoUris: ['file://selected/no-extension'] }); await tick();
    assert.deepEqual(results, ['selected']); f.picker.revoke();
  }
  {
    const f = fixture({ size: 32 * 1024 * 1024 + 1 }), results = [];
    f.picker.select({ ...request(['image/*']), maxBytes: 32 * 1024 * 1024, validateMime: false }, result => results.push(result.status));
    f.resolveSelection({ photoUris: ['file://selected/huge.jpg'] }); await tick();
    assert.deepEqual(results, ['tooLarge']); f.picker.revoke();
  }
  for (const code of [201, 13900012]) {
    const f = fixture(), results = [];
    f.picker.select(request(['image/*']), result => results.push(result.status));
    f.rejectSelection({ code }); await tick();
    assert.deepEqual(results, ['permissionDenied']); f.picker.revoke();
  }
});

test('permission, picker and visibility failures remain distinct and settle once', async () => {
  for (const scenario of ['notGranted', 'visibilityFailure', 'pickerFailure']) {
    const f = fixture(), results = [];
    const input = { ...request(['image/jpeg']), capture: scenario !== 'pickerFailure', captureEnabled: true,
      visible: () => scenario !== 'visibilityFailure',
      waitVisible: async () => { throw Error('visibility'); }, authorizeCapture: async () => scenario !== 'notGranted' };
    f.picker.select(input, value => results.push(value.status));
    if (scenario === 'pickerFailure') f.resolveSelection({ photoUris: null });
    await tick();
    assert.deepEqual(results, [scenario === 'notGranted' ? 'notGranted' : 'failed']);
    f.picker.revoke();
  }
});
