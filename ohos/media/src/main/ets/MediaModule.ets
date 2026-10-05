import { KRAny, KuiklyRenderBaseModule, KuiklyRenderCallback } from '@kuikly-open/render';
import { camera, cameraPicker } from '@kit.CameraKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

interface MediaArgs {
  requestId?: string;
  source?: string;
  maxCount?: number;
  maxDimension?: number;
  jpegQuality?: number;
  data?: string;
  fileNamePrefix?: string;
}
interface MediaImage { data: string; fileName: string; contentType: string; }
interface MediaResult { status: string; images?: MediaImage[]; value?: string; }

/** 系统 Picker 不可强制关闭；本次等待可结束，原生收尾仍按自己的请求继续释放资源。 */
class PendingMediaRequest {
  cancelled: boolean = false;
  readonly cancellation: Promise<MediaResult>;
  private completeCancellation: ((result: MediaResult) => void) | null = null;

  constructor() {
    this.cancellation = new Promise<MediaResult>((resolve) => { this.completeCancellation = resolve; });
  }

  cancel(): void {
    if (this.cancelled) { return; }
    this.cancelled = true;
    this.completeCancellation?.({ status: 'cancelled' });
    this.completeCancellation = null;
  }
}

/** 使用系统 Picker 和逐次保存授权，不申请整库读写权限。 */
export class MediaModule extends KuiklyRenderBaseModule {
  /** Kuikly 注册名，与 Kotlin 侧常量一致。 */
  static readonly MODULE_NAME: string = 'GycMedia';
  private readonly maxBytes: number = 32 * 1024 * 1024;
  private destroyed: boolean = false;
  private picking: boolean = false;
  private sequence: number = 0;
  private readonly identifier: string = util.generateRandomUUID(true);
  private base64: util.Base64Helper = new util.Base64Helper();
  private readonly requests: Map<string, PendingMediaRequest> = new Map();

  syncMode(): boolean { return false; }

  /** 页面线程异步入口；销毁后忽略请求与迟到回调，参数 JSON 属于输入边界。 */
  call(method: string, params: KRAny, callback: KuiklyRenderCallback | null): KRAny {
    if (this.destroyed) { return null; }
    let args: MediaArgs;
    try { args = JSON.parse(typeof params === 'string' ? params : '{}') as MediaArgs; }
    catch (_) { callback?.({ status: 'invalid_content' }); return null; }
    if (!args || typeof args !== 'object') { callback?.({ status: 'invalid_content' }); return null; }
    if (method === 'cancel') {
      if (typeof args.requestId === 'string') { this.requests.get(args.requestId)?.cancel(); }
      return null;
    }
    // 旧调用方不提供 ID 时仍可工作；新版 Kotlin/HAR 成对接入后才支持请求级取消。
    const id = typeof args.requestId === 'string' && args.requestId.length > 0 ?
      args.requestId : `legacy_${this.sequence++}`;
    if (this.requests.has(id)) { callback?.({ status: 'failed' }); return null; }
    const request = new PendingMediaRequest();
    this.requests.set(id, request);
    const operation = this.perform(method, args, request).catch((error: BusinessError): MediaResult => {
      return { status: error.code === 201 || error.code === 13900012 ? 'permission_denied' : 'failed' };
    });
    Promise.race([operation, request.cancellation]).then((result: MediaResult) => {
      if (!this.destroyed) { callback?.(result); }
    }).finally(() => {
      if (this.requests.get(id) === request) { this.requests.delete(id); }
    });
    return null;
  }

  private async perform(method: string, args: MediaArgs, request: PendingMediaRequest): Promise<MediaResult> {
    if (this.destroyed || request.cancelled) { return { status: 'cancelled' }; }
    if (method === 'pick') { return this.pick(args, request); }
    if (method !== 'save') { return { status: 'failed' }; }
    if (typeof args.data !== 'string' || args.data.length > Math.ceil(this.maxBytes / 3) * 4) {
      return { status: 'invalid_content' };
    }
    const padding = args.data.endsWith('==') ? 2 : args.data.endsWith('=') ? 1 : 0;
    if (Math.floor(args.data.length * 3 / 4) - padding > this.maxBytes) { return { status: 'invalid_content' }; }
    const bytes = this.base64.decodeSync(args.data);
    if (bytes.byteLength === 0 || bytes.byteLength > this.maxBytes) { return { status: 'invalid_content' }; }
    return this.save(bytes.buffer as ArrayBuffer, args.fileNamePrefix ?? 'image', request);
  }

  private async pick(args: MediaArgs, request: PendingMediaRequest): Promise<MediaResult> {
    const context = this.controller?.getUIAbilityContext();
    const count = args.maxCount ?? 1;
    const dimension = args.maxDimension ?? 0;
    const quality = args.jpegQuality ?? 0;
    if (!context || !Number.isInteger(count) || count < 1 || count > 500 ||
      !Number.isInteger(dimension) || dimension < 0 ||
      (dimension > 0 && (!Number.isInteger(quality) || quality < 1 || quality > 100))) {
      return { status: 'failed' };
    }
    if (this.picking) { return { status: 'busy' }; }
    this.picking = true;
    let cameraPath = '';
    try {
      let uris: string[];
      if (args.source === 'CAMERA') {
        cameraPath = this.tempPath('jpg');
        const file = await fs.open(cameraPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
        await fs.close(file);
        if (this.destroyed || request.cancelled) { return { status: 'cancelled' }; }
        const capture = await cameraPicker.pick(context, [cameraPicker.PickerMediaType.PHOTO], {
          cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK,
          saveUri: fileUri.getUriFromPath(cameraPath)
        });
        if (this.destroyed || request.cancelled) { return { status: 'cancelled' }; }
        // API 仅承诺 -1 为失败，不能把权限或相机失败一律当作取消。
        if (capture.resultCode !== 0) { return { status: 'failed' }; }
        if (!capture.resultUri) { return { status: 'cancelled' }; }
        uris = [capture.resultUri];
      } else if (args.source === 'GALLERY') {
        const picker = new photoAccessHelper.PhotoViewPicker();
        const selected = await picker.select({
          MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE, maxSelectNumber: count
        });
        if (this.destroyed || request.cancelled) { return { status: 'cancelled' }; }
        uris = selected.photoUris;
      } else { return { status: 'failed' }; }
      if (uris.length === 0) { return { status: 'cancelled' }; }
      if (this.destroyed || request.cancelled) { return { status: 'cancelled' }; }
      const images: MediaImage[] = [];
      let total = 0;
      let outputTotal = 0;
      for (let index = 0; index < uris.length; index++) {
        if (this.destroyed || request.cancelled) { return { status: 'cancelled' }; }
        const original = await this.read(uris[index], this.maxBytes - total, request);
        total += original.byteLength;
        // ponytail: JSON Base64 需要额外内存，单次原图合计限 32 MiB；大图改为二进制分块桥。
        if (total > this.maxBytes) { return { status: 'failed' }; }
        if (this.destroyed || request.cancelled) { return { status: 'cancelled' }; }
        const source = image.createImageSource(original);
        try {
          const info = await source.getImageInfo();
          if (this.destroyed || request.cancelled) { return { status: 'cancelled' }; }
          let bytes = original;
          let mime = info.mimeType;
          if (dimension > 0) {
            const ratio = Math.min(1, dimension / Math.max(info.size.width, info.size.height));
            const pixels = await source.createPixelMap({ desiredSize: {
              width: Math.max(1, Math.round(info.size.width * ratio)),
              height: Math.max(1, Math.round(info.size.height * ratio))
            } });
            try {
              if (this.destroyed || request.cancelled) { return { status: 'cancelled' }; }
              const packer = image.createImagePacker();
              try { bytes = await packer.packing(pixels, { format: 'image/jpeg', quality }); }
              finally { await packer.release(); }
            } finally { await pixels.release(); }
            mime = 'image/jpeg';
          }
          if (this.destroyed || request.cancelled) { return { status: 'cancelled' }; }
          outputTotal += bytes.byteLength;
          if (bytes.byteLength === 0 || outputTotal > this.maxBytes) { return { status: 'failed' }; }
          images.push({ data: this.base64.encodeToStringSync(new Uint8Array(bytes)),
            fileName: `image_${Date.now()}_${index}.${this.extension(mime)}`, contentType: mime });
        } finally { await source.release(); }
      }
      return { status: 'selected', images };
    } finally {
      this.picking = false;
      if (cameraPath) { await this.removeTemp(cameraPath); }
    }
  }

  private async save(bytes: ArrayBuffer, prefix: string, request: PendingMediaRequest): Promise<MediaResult> {
    const context = this.controller?.getUIAbilityContext();
    if (!context) { return { status: 'failed' }; }
    const source = image.createImageSource(bytes);
    let extension: string;
    try { extension = this.extension((await source.getImageInfo()).mimeType); }
    catch (_) { return { status: 'invalid_content' }; }
    finally { await source.release(); }
    if (this.destroyed || request.cancelled) { return { status: 'cancelled' }; }
    if (extension === 'bin') { return { status: 'invalid_content' }; }
    const path = this.tempPath(extension);
    const helper = photoAccessHelper.getPhotoAccessHelper(context);
    try {
      await this.write(path, bytes, true, request);
      if (this.destroyed || request.cancelled) { return { status: 'cancelled' }; }
      const title = prefix.replace(/[\\/:*?"'`<>|{}\[\]\u0000-\u001f]/g, '_').slice(0, 100) || 'image';
      const uris = await helper.showAssetsCreationDialog([fileUri.getUriFromPath(path)], [{
        title, fileNameExtension: extension, photoType: photoAccessHelper.PhotoType.IMAGE
      }]);
      if (this.destroyed || request.cancelled) { return { status: 'cancelled' }; }
      if (uris.length === 0) { return { status: 'cancelled' }; }
      if (uris.length !== 1 || !uris[0].startsWith('file://')) { return { status: 'failed' }; }
      // 只有目标文件写入并关闭成功才报告 SAVED，授权成功本身不等于保存完成。
      await this.write(uris[0], bytes, false, request);
      if (this.destroyed || request.cancelled) { return { status: 'cancelled' }; }
      return { status: 'saved' };
    } finally {
      try { await helper.release(); } finally { await this.removeTemp(path); }
    }
  }

  private async read(uri: string, remainingBytes: number, request: PendingMediaRequest): Promise<ArrayBuffer> {
    if (this.destroyed || request.cancelled) { throw new Error('Media request cancelled'); }
    const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
    try {
      const size = (await fs.stat(file.fd)).size;
      if (size <= 0 || size > remainingBytes) { throw new Error('Invalid image size'); }
      if (this.destroyed || request.cancelled) { throw new Error('Media request cancelled'); }
      const result = new Uint8Array(size);
      let offset = 0;
      while (offset < size) {
        if (this.destroyed || request.cancelled) { throw new Error('Media request cancelled'); }
        const chunk = new ArrayBuffer(size - offset);
        const length = await fs.read(file.fd, chunk);
        if (this.destroyed || request.cancelled) { throw new Error('Media request cancelled'); }
        if (length <= 0) { throw new Error('Incomplete image'); }
        result.set(new Uint8Array(chunk, 0, length), offset);
        offset += length;
      }
      return result.buffer as ArrayBuffer;
    } finally { await fs.close(file); }
  }

  private async write(path: string, bytes: ArrayBuffer, create: boolean, request: PendingMediaRequest): Promise<void> {
    if (this.destroyed || request.cancelled) { throw new Error('Media request cancelled'); }
    const file = await fs.open(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC | (create ? fs.OpenMode.CREATE : 0));
    try {
      let offset = 0;
      while (offset < bytes.byteLength) {
        if (this.destroyed || request.cancelled) { throw new Error('Media request cancelled'); }
        const length = await fs.write(file.fd, bytes.slice(offset));
        if (length <= 0) { throw new Error('Incomplete image write'); }
        offset += length;
      }
    } finally { await fs.close(file); }
  }

  private tempPath(extension: string): string {
    const context = this.controller?.getUIAbilityContext();
    if (!context) { throw new Error('Media host unavailable'); }
    // 多页面 Module 共用 cacheDir；时间戳加实例内序号不能隔离同毫秒请求。
    return `${context.cacheDir}/media_${this.identifier}_${this.sequence++}.${extension}`;
  }

  private async removeTemp(path: string): Promise<void> {
    try { await fs.unlink(path); } catch (_) { /* 文件可能已经被系统清理。 */ }
  }

  private extension(mime: string): string {
    switch (mime) {
      case 'image/jpeg': return 'jpg';
      case 'image/png': return 'png';
      case 'image/webp': return 'webp';
      case 'image/gif': return 'gif';
      case 'image/heif': return 'heif';
      case 'image/heic': return 'heic';
      case 'image/bmp': return 'bmp';
      default: return 'bin';
    }
  }

  onDestroy(): void {
    this.destroyed = true;
    this.requests.forEach((request: PendingMediaRequest) => { request.cancel(); });
    this.requests.clear();
    super.onDestroy();
  }
}
