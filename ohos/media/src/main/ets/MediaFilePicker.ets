import { common } from '@kit.AbilityKit';
import { picker, fileIo, fileUri } from '@kit.CoreFileKit';
import { camera, cameraPicker } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { media } from '@kit.MediaKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { uniformTypeDescriptor } from '@kit.ArkData';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

export interface MediaFileSelectionRequest {
  context: common.UIAbilityContext;
  uiContext: UIContext | null;
  acceptTypes: string[];
  multiple: boolean;
  capture: boolean;
  captureEnabled: boolean;
  maxFiles?: number;
  maxBytes?: number;
  validateMime?: boolean;
  valid: () => boolean;
  visible: () => boolean;
  waitVisible: () => Promise<void>;
  authorizeCapture: (video: boolean) => Promise<boolean>;
}
export interface MediaSelectedFile { uri: string; name: string; mimeType: string; size: number; }
export type MediaFileSelectionStatus = 'selected' | 'cancelled' | 'notGranted' | 'permissionDenied' | 'tooLarge' | 'failed';
export interface MediaFileSelectionResult { status: MediaFileSelectionStatus; files: MediaSelectedFile[]; }

function fileExtension(name: string): string {
  const index = name.lastIndexOf('.');
  return index > 0 ? name.slice(index).toLowerCase() : '';
}
// ArkWeb 可把 wildcard 展开为 Chromium 的后缀集合；UTD 不保证认识全部别名。
function canonicalType(type: string): string {
  switch (type) {
    case '*': return '*/*';
    case 'image': return 'image/*';
    case 'video': return 'video/*';
    case '.jpg': case '.jpeg': case '.jpe': case '.jfif': case '.pjpeg': case '.pjp':
    case 'image/jpg': case 'image/pjpeg': return 'image/jpeg';
    case '.png': case 'image/x-png': return 'image/png';
    case '.apng': return 'image/apng';
    case '.gif': return 'image/gif';
    case '.webp': return 'image/webp';
    case '.bmp': return 'image/bmp';
    case '.ico': case 'image/vnd.microsoft.icon': return 'image/x-icon';
    case '.avif': return 'image/avif';
    case '.jxl': return 'image/jxl';
    case '.tif': case '.tiff': return 'image/tiff';
    case '.svg': case '.svgz': return 'image/svg+xml';
    case '.xbm': return 'image/x-xbitmap';
    case '.heif': return 'image/heif';
    case '.heic': return 'image/heic';
    case '.mp4': case '.m4v': case '.mp4v': case '.mpg4': return 'video/mp4';
    case '.mov': case '.qt': case 'video/mov': return 'video/quicktime';
    case '.webm': return 'video/webm';
    case '.ogv': case '.ogm': return 'video/ogg';
    case '.mpeg': case '.mpg': case '.mpe': case '.m1v': case '.m2v': return 'video/mpeg';
    default: return type;
  }
}
function normalizedType(type: string): string {
  const canonical = canonicalType(type);
  if (!canonical.startsWith('.')) return canonical;
  try {
    const id = uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(canonical);
    const descriptor = uniformTypeDescriptor.getTypeDescriptor(id);
    const mimes = descriptor?.mimeTypes ?? [];
    if (mimes.length > 0 && mimes.every(mime => mime.startsWith('image/') || mime.startsWith('video/'))) {
      return canonicalType(mimes[0].toLowerCase());
    }
  } catch (_) {}
  return canonical;
}
function selectionError(error: BusinessError): MediaFileSelectionStatus {
  return error?.code === 201 || error?.code === 13900012 ? 'permissionDenied' : 'failed';
}

/** 系统选择器独立处理媒体；调用方负责请求授权和生命周期。 */
export class MediaFilePicker {
  private readonly files: Set<string> = new Set();

  static pickGallery(maxFiles: number, mime: photoAccessHelper.PhotoViewMIMETypes): Promise<photoAccessHelper.PhotoSelectResult> {
    return new photoAccessHelper.PhotoViewPicker().select({ MIMEType: mime, maxSelectNumber: maxFiles });
  }
  static pickCamera(context: common.UIAbilityContext, uri: string, video: boolean): Promise<cameraPicker.PickerResult> {
    const profile: cameraPicker.PickerProfile = { cameraPosition: camera.CameraPosition.CAMERA_POSITION_BACK, saveUri: uri };
    if (video) profile.videoDuration = 60;
    return cameraPicker.pick(context, [video ? cameraPicker.PickerMediaType.VIDEO : cameraPicker.PickerMediaType.PHOTO], profile);
  }

  revoke(): void {
    const files = Array.from(this.files); this.files.clear();
    files.forEach(path => { try { fileIo.unlinkSync(path); } catch (_) {} });
  }

  select(request: MediaFileSelectionRequest, callback: (result: MediaFileSelectionResult) => void): void {
    const context = request.context;
    const valid = request.valid;
    const maxFiles = request.multiple ? (request.maxFiles ?? 10) : 1;
    const maxBytes = request.maxBytes ?? 50 * 1024 * 1024;
    const trace = (route: string): void => {
      try { hilog.debug(0x30, 'GycMediaPicker', 'route=%{public}s maxCount=%{public}d capture=%{public}s', route, maxFiles, String(request.capture)); } catch (_) {}
    };
    let completed = false;
    const complete = (files: MediaSelectedFile[], status: MediaFileSelectionStatus = files.length ? 'selected' : 'cancelled'): void => {
      if (completed) return;
      completed = true;
      callback(valid() ? { status, files } : { status: 'cancelled', files: [] });
    };
    try {
      if (!Number.isInteger(maxFiles) || maxFiles < 1 || maxFiles > 500 || !Number.isInteger(maxBytes) || maxBytes < 1 || maxBytes > 50 * 1024 * 1024) { complete([], 'failed'); return; }
      const accepts = request.acceptTypes.flatMap(type => type.split(',')).map(type => normalizedType(type.trim().toLowerCase())).filter(type => !!type);
      if (request.capture) {
        const any = accepts.length === 0 || accepts.includes('*/*');
        const jpeg = any || accepts.some(type => type === 'image/*' || type === 'image/jpeg');
        const png = accepts.some(type => type === 'image/png');
        const photo = jpeg || png;
        const movie = any || accepts.some(type => type === 'video/*' || type === 'video/mp4');
        if (!request.captureEnabled || (!photo && !movie)) {
          complete([], 'failed'); return;
        }
        const capture = (video: boolean): void => {
          request.authorizeCapture(video).then(async granted => {
            if (!valid()) { complete([]); return; }
            if (!granted) { complete([], 'notGranted'); return; }
            if (!request.visible()) await request.waitVisible();
            if (!valid() || !request.visible()) { complete([]); return; }
            const path = `${context.cacheDir}/gy-media-${util.generateRandomUUID()}${video ? '.mp4' : '.jpg'}`;
            const file = fileIo.openSync(path, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE); fileIo.closeSync(file);
            this.files.add(path);
            const uri = fileUri.getUriFromPath(path);
            const mediaType = video ? cameraPicker.PickerMediaType.VIDEO : cameraPicker.PickerMediaType.PHOTO;
            let pngPath: string | null = null;
            try {
              trace(video ? 'camera-video' : 'camera-photo');
              const result = await MediaFilePicker.pickCamera(context, uri, video);
              if (!valid()) { this.files.delete(path); try { fileIo.unlinkSync(path); } catch (_) {} complete([]); return; }
              if (result.resultCode === 0 && !result.resultUri) {
                this.files.delete(path); try { fileIo.unlinkSync(path); } catch (_) {} complete([]); return;
              }
              const input = await fileIo.open(path, fileIo.OpenMode.READ_ONLY);
              if (!valid()) {
                await fileIo.close(input); this.files.delete(path); try { fileIo.unlinkSync(path); } catch (_) {} complete([]); return;
              }
              let selected: MediaSelectedFile | null = null;
              let failure: MediaFileSelectionStatus = 'failed';
              try {
                const size = (await fileIo.stat(input.fd)).size;
                if (!valid()) throw Error('Selection revoked');
                const header = new ArrayBuffer(12);
                const bytesRead = await fileIo.read(input.fd, header, { offset: 0 });
                if (!valid()) throw Error('Selection revoked');
                const bytes = new Uint8Array(header);
                const mediaMatches = video ? bytesRead >= 12 && bytes[4] === 0x66 && bytes[5] === 0x74 && bytes[6] === 0x79 && bytes[7] === 0x70 :
                  bytesRead >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
                const accepted = valid() && result.resultCode === 0 && result.resultUri === uri && result.mediaType === mediaType && mediaMatches && size > 0 && size <= maxBytes;
                if (!accepted) { failure = size > maxBytes ? 'tooLarge' : 'failed'; }
                else if (video || jpeg) {
                  selected = { uri, name: new fileUri.FileUri(uri).name, mimeType: video ? 'video/mp4' : 'image/jpeg', size };
                } else {
                  pngPath = `${context.cacheDir}/gy-media-${util.generateRandomUUID()}.png`;
                  let target: fileIo.File | null = null;
                  let source: image.ImageSource | null = null;
                  let packer: image.ImagePacker | null = null;
                  try {
                    fileIo.lseek(input.fd, 0, fileIo.WhenceType.SEEK_SET);
                    source = image.createImageSource(input.fd);
                    packer = image.createImagePacker();
                    target = await fileIo.open(pngPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
                    this.files.add(pngPath);
                    if (!valid()) throw Error('Selection revoked');
                    await packer.packToFile(source, target.fd, { format: 'image/png', quality: 100 });
                    if (!valid()) throw Error('Selection revoked');
                    const pngSize = (await fileIo.stat(target.fd)).size;
                    const pngHeader = new ArrayBuffer(8);
                    fileIo.lseek(target.fd, 0, fileIo.WhenceType.SEEK_SET);
                    const pngRead = await fileIo.read(target.fd, pngHeader, { offset: 0 });
                    const signature = new Uint8Array(pngHeader);
                    const pngValid = pngRead === 8 && [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a].every((byte, index) => signature[index] === byte);
                    if (valid() && pngValid && pngSize > 0 && pngSize <= maxBytes) {
                      const pngUri = fileUri.getUriFromPath(pngPath);
                      selected = { uri: pngUri, name: new fileUri.FileUri(pngUri).name, mimeType: 'image/png', size: pngSize };
                    } else failure = pngSize > maxBytes ? 'tooLarge' : 'failed';
                  } finally {
                    try { try { await packer?.release(); } finally { await source?.release(); } }
                    finally { if (target) await fileIo.close(target); }
                  }
                }
              } finally { await fileIo.close(input); }
              if (!valid() || !selected || selected.uri !== uri) {
                this.files.delete(path); try { fileIo.unlinkSync(path); } catch (_) {}
              }
              if (!valid() || !selected) {
                if (pngPath) { this.files.delete(pngPath); try { fileIo.unlinkSync(pngPath); } catch (_) {} }
                complete([], valid() ? failure : 'cancelled'); return;
              }
              complete([selected]);
            } catch (error) {
              this.files.delete(path); try { fileIo.unlinkSync(path); } catch (_) {}
              if (pngPath) { this.files.delete(pngPath); try { fileIo.unlinkSync(pngPath); } catch (_) {} }
              complete([], selectionError(error as BusinessError));
            }
          }).catch((error: BusinessError) => complete([], selectionError(error)));
        };
        if (photo && movie) {
          const chinese = context.config.language?.startsWith('zh') === true;
          const uiContext = request.uiContext;
          if (!uiContext) { complete([], 'failed'); return; }
          uiContext.getPromptAction().showActionMenu({ buttons: [
            { text: chinese ? '拍照' : 'Take photo', color: $r('sys.color.font_primary') },
            { text: chinese ? '录视频' : 'Record video', color: $r('sys.color.font_primary') },
          ] }).then(choice => {
            if (!valid() || (choice.index !== 0 && choice.index !== 1)) { complete([]); return; }
            capture(choice.index === 1);
          }).catch(() => complete([], 'failed'));
        } else capture(movie);
        return;
      }
      let images = false;
      let videos = false;
      let mediaOnly = accepts.length > 0;
      for (const type of accepts) {
        if (type.startsWith('image/')) images = true;
        else if (type.startsWith('video/')) videos = true;
        else mediaOnly = false;
      }
      let selection: Promise<string[]>;
      if (mediaOnly && (images || videos)) {
        trace(images && videos ? 'mixed' : images ? 'photos' : 'videos');
        const mime = images && videos ? photoAccessHelper.PhotoViewMIMETypes.IMAGE_VIDEO_TYPE :
          images ? photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE : photoAccessHelper.PhotoViewMIMETypes.VIDEO_TYPE;
        selection = MediaFilePicker.pickGallery(maxFiles, mime).then(result => result.photoUris);
      } else {
        trace('documents');
        const options = new picker.DocumentSelectOptions();
        options.maxSelectNumber = maxFiles;
        selection = new picker.DocumentViewPicker(context).select(options);
      }
      selection.then(async values => {
        // 图库返回后再读取临时授权 URI，且等待宿主恢复可见。
        if (mediaOnly && (images || videos)) {
          await new Promise<void>(resolve => setTimeout(resolve, 0));
          if (!request.visible() && valid()) await request.waitVisible();
        }
        if (!valid()) { complete([]); return; }
        if (values.length > maxFiles) { complete([], 'failed'); return; }
        const files: MediaSelectedFile[] = [];
        for (const uri of values) {
          if (!valid()) { complete([]); return; }
          const name = new fileUri.FileUri(uri).name;
          const extension = fileExtension(name);
          const knownType = canonicalType(extension);
          let mimeType = knownType.includes('/') ? knownType : 'application/octet-stream';
          if (extension && mimeType === 'application/octet-stream') {
            try {
              const descriptor = uniformTypeDescriptor.getTypeDescriptor(uniformTypeDescriptor.getUniformDataTypeByFilenameExtension(extension));
              mimeType = descriptor?.mimeTypes[0] ?? mimeType;
            } catch (_) {}
          }
          const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
          let size: number;
          try {
            if (!valid()) { complete([]); return; }
            size = (await fileIo.stat(file.fd)).size;
            // 无后缀媒体从同一已授权 FD 获取真实 MIME，不凭请求类型猜测。
            if (valid() && size > 0 && size <= maxBytes && !extension && request.validateMime !== false &&
              accepts.some(type => type.startsWith('image/')) && !accepts.includes('*/*')) {
              let source: image.ImageSource | null = null;
              try {
                source = image.createImageSource(file.fd);
                const info = await source.getImageInfo();
                if (info.mimeType?.startsWith('image/')) mimeType = canonicalType(info.mimeType.toLowerCase());
              } catch (_) {} finally { await source?.release(); }
            }
            if (valid() && size > 0 && size <= maxBytes && !extension && mimeType === 'application/octet-stream' &&
              request.validateMime !== false && accepts.some(type => type.startsWith('video/')) && !accepts.includes('*/*')) {
              let extractor: media.AVMetadataExtractor | null = null;
              try {
                extractor = await media.createAVMetadataExtractor();
                if (valid()) {
                  extractor.fdSrc = { fd: file.fd, offset: 0, length: size };
                  const metadata = await extractor.fetchMetadata();
                  if (metadata.mimeType?.startsWith('video/')) mimeType = canonicalType(metadata.mimeType.toLowerCase());
                }
              } catch (_) {} finally { await extractor?.release(); }
            }
          }
          finally { await fileIo.close(file); }
          if (!valid()) { complete([]); return; }
          if (size > maxBytes) { complete([], 'tooLarge'); return; }
          if (size <= 0) { complete([], 'failed'); return; }
          const mimeMatches = request.validateMime === false || accepts.length === 0 || accepts.includes('*/*') || accepts.includes(extension) ||
            accepts.some(type => type === mimeType || (type.endsWith('/*') && mimeType.startsWith(type.slice(0, -1))));
          if (!mimeMatches) { complete([], 'failed'); return; }
          files.push({ uri, name, mimeType, size });
        }
        complete(files);
      }).catch((error: BusinessError) => complete([], selectionError(error)));
      return;
    } catch (error) { complete([], selectionError(error as BusinessError)); }
  }
}
