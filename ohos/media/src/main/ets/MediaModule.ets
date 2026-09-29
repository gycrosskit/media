import { KRAny, KuiklyRenderBaseModule, KuiklyRenderCallback } from '@kuikly-open/render';
import { camera, cameraPicker } from '@kit.CameraKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { image } from '@kit.ImageKit';
import { fileIo as fs, fileUri } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';

interface MediaArgs {
  source?: string;
  maxCount?: number;
  maxDimension?: number;
  jpegQuality?: number;
  data?: string;
  fileNamePrefix?: string;
}
interface MediaImage { data: string; fileName: string; contentType: string; }
interface MediaResult { status: string; images?: MediaImage[]; value?: string; }

/** 使用系统 Picker 和逐次保存授权，不申请整库读写权限。 */
export class MediaModule extends KuiklyRenderBaseModule {
  static readonly MODULE_NAME: string = 'GycMedia';
  private readonly maxBytes: number = 32 * 1024 * 1024;
  private destroyed: boolean = false;
  private picking: boolean = false;
  private sequence: number = 0;
  private base64: util.Base64Helper = new util.Base64Helper();

  syncMode(): boolean { return false; }

  call(method: string, params: KRAny, callback: KuiklyRenderCallback | null): KRAny {
    this.perform(method, params).then((result: MediaResult) => {
      if (!this.destroyed) { callback?.(result); }
    }).catch((error: BusinessError) => {
      if (!this.destroyed) {
        callback?.({ status: error.code === 201 || error.code === 13900012 ?
          'permission_denied' : 'failed' });
      }
    });
    return null;
  }

  private async perform(method: string, params: KRAny): Promise<MediaResult> {
    if (this.destroyed || typeof params !== 'string') { return { status: 'failed' }; }
    const args = JSON.parse(params) as MediaArgs;
    if (!args || typeof args !== 'object') { return { status: 'invalid_content' }; }
    if (method === 'pick') { return this.pick(args); }
    if (typeof args.data !== 'string' || args.data.length > Math.ceil(this.maxBytes / 3) * 4) {
      return { status: 'invalid_content' };
    }
    const bytes = this.base64.decodeSync(args.data);
    if (bytes.byteLength === 0 || bytes.byteLength > this.maxBytes) { return { status: 'invalid_content' }; }
    if (method === 'save') { return this.save(bytes.buffer as ArrayBuffer, args.fileNamePrefix ?? 'image'); }
    return { status: 'failed' };
  }

  private async pick(args: MediaArgs): Promise<MediaResult> {
    const context = this.controller?.getUIAbilityContext();
    const count = args.maxCount ?? 1;
    const dimension = args.maxDimension ?? 0;
    const quality = args.jpegQuality ?? 0;
    if (!context || this.picking || !Number.isInteger(count) || count < 1 || count > 500 ||
      !Number.isInteger(dimension) || dimension < 0 ||
      (dimension > 0 && (!Number.isInteger(quality) || quality < 1 || quality > 100))) {
      return { status: 'failed' };
    }
    this.picking = true;
    let cameraPath = '';
    try {
      let uris: string[];
      if (args.source === 'CAMERA') {
        cameraPath = this.tempPath('jpg');
        const file = await fs.open(cameraPath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE);
        await fs.close(file);
        if (this.destroyed) { return { status: 'cancelled' }; }
        const capture = await cameraPicker.pick(context, [cameraPicker.PickerMediaType.PHOTO], {
          cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK,
          saveUri: fileUri.getUriFromPath(cameraPath)
        });
        // API 仅承诺 -1 为失败，不能把权限或相机失败一律当作取消。
        if (capture.resultCode !== 0) { return { status: 'failed' }; }
        if (!capture.resultUri) { return { status: 'cancelled' }; }
        uris = [capture.resultUri];
      } else if (args.source === 'GALLERY') {
        const picker = new photoAccessHelper.PhotoViewPicker();
        const selected = await picker.select({
          MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE, maxSelectNumber: count
        });
        uris = selected.photoUris;
      } else { return { status: 'failed' }; }
      if (uris.length === 0) { return { status: 'cancelled' }; }
      if (this.destroyed) { return { status: 'cancelled' }; }
      const images: MediaImage[] = [];
      let total = 0;
      for (let index = 0; index < uris.length; index++) {
        const original = await this.read(uris[index]);
        total += original.byteLength;
        // ponytail: JSON Base64 需要额外内存，单次原图合计限 32 MiB；大图改为二进制分块桥。
        if (total > this.maxBytes) { return { status: 'failed' }; }
        const source = image.createImageSource(original);
        try {
          const info = await source.getImageInfo();
          let bytes = original;
          let mime = info.mimeType;
          if (dimension > 0) {
            const ratio = Math.min(1, dimension / Math.max(info.size.width, info.size.height));
            const pixels = await source.createPixelMap({ desiredSize: {
              width: Math.max(1, Math.round(info.size.width * ratio)),
              height: Math.max(1, Math.round(info.size.height * ratio))
            } });
            const packer = image.createImagePacker();
            try { bytes = await packer.packing(pixels, { format: 'image/jpeg', quality }); }
            finally { await packer.release(); await pixels.release(); }
            mime = 'image/jpeg';
          }
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

  private async save(bytes: ArrayBuffer, prefix: string): Promise<MediaResult> {
    const context = this.controller?.getUIAbilityContext();
    if (!context) { return { status: 'failed' }; }
    const source = image.createImageSource(bytes);
    let extension: string;
    try { extension = this.extension((await source.getImageInfo()).mimeType); }
    catch (_) { return { status: 'invalid_content' }; }
    finally { await source.release(); }
    if (extension === 'bin') { return { status: 'invalid_content' }; }
    const path = this.tempPath(extension);
    const helper = photoAccessHelper.getPhotoAccessHelper(context);
    try {
      await this.write(path, bytes, true);
      if (this.destroyed) { return { status: 'cancelled' }; }
      const title = prefix.replace(/[\\/:*?"'`<>|{}\[\]\u0000-\u001f]/g, '_').slice(0, 100) || 'image';
      const uris = await helper.showAssetsCreationDialog([fileUri.getUriFromPath(path)], [{
        title, fileNameExtension: extension, photoType: photoAccessHelper.PhotoType.IMAGE
      }]);
      if (uris.length === 0) { return { status: 'cancelled' }; }
      if (uris.length !== 1 || !uris[0].startsWith('file://')) { return { status: 'failed' }; }
      // 只有目标文件写入并关闭成功才报告 SAVED，授权成功本身不等于保存完成。
      await this.write(uris[0], bytes, false);
      return { status: 'saved' };
    } finally { await helper.release(); await this.removeTemp(path); }
  }

  private async read(uri: string): Promise<ArrayBuffer> {
    const file = await fs.open(uri, fs.OpenMode.READ_ONLY);
    try {
      const size = (await fs.stat(file.fd)).size;
      if (size <= 0 || size > this.maxBytes) { throw new Error('Invalid image size'); }
      const result = new Uint8Array(size);
      let offset = 0;
      while (offset < size) {
        const chunk = new ArrayBuffer(size - offset);
        const length = await fs.read(file.fd, chunk);
        if (length <= 0) { throw new Error('Incomplete image'); }
        result.set(new Uint8Array(chunk, 0, length), offset);
        offset += length;
      }
      return result.buffer as ArrayBuffer;
    } finally { await fs.close(file); }
  }

  private async write(path: string, bytes: ArrayBuffer, create: boolean): Promise<void> {
    const file = await fs.open(path, fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC | (create ? fs.OpenMode.CREATE : 0));
    try {
      let offset = 0;
      while (offset < bytes.byteLength) {
        const length = await fs.write(file.fd, bytes.slice(offset));
        if (length <= 0) { throw new Error('Incomplete image write'); }
        offset += length;
      }
    } finally { await fs.close(file); }
  }

  private tempPath(extension: string): string {
    const context = this.controller?.getUIAbilityContext();
    if (!context) { throw new Error('Media host unavailable'); }
    return `${context.cacheDir}/media_${Date.now()}_${this.sequence++}.${extension}`;
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

  onDestroy(): void { this.destroyed = true; super.onDestroy(); }
}
