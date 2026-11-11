import { HgAsyncCover } from '../HgAsyncCover';
import { HgColor, HgFont, HgIconSize, HgRadius, HgSpace } from '../../design/HgTokens';
import { Api } from '../../services/Api';
import { parseWebUrl } from '../../utils/Security';

/** 正文里的一段行内文本（支持加粗/斜体/链接）。 */
export class HgInline {
  text: string = '';
  bold: boolean = false;
  italic: boolean = false;
  link: string = '';
}

/** 正文的一个块级节点。 */
export class HgBlock {
  /** p / h1 / h2 / h3 / h4 / ul / ol / quote / img / hr */
  kind: string = 'p';
  spans: HgInline[] = [];
  /** 列表项：每项是一组行内文本 */
  items: HgInline[][] = [];
  src: string = '';
  alt: string = '';
  /** 图片高宽比（height / width），用于原生比例占位 */
  ratio: number = 9 / 16;
  /** 本块内出现的可点链接（去重） */
  links: string[] = [];
}

function decodeEntities(raw: string): string {
  let out = raw;
  out = out.replace(/&nbsp;/g, ' ');
  out = out.replace(/&amp;/g, '&');
  out = out.replace(/&lt;/g, '<');
  out = out.replace(/&gt;/g, '>');
  out = out.replace(/&quot;/g, '"');
  out = out.replace(/&#39;/g, "'");
  out = out.replace(/&apos;/g, "'");
  out = out.replace(/&#(\d+);/g, (match: string, code: string) => {
    const value = Number(code);
    if (isNaN(value) || value <= 0 || value > 65535) {
      return '';
    }
    return String.fromCharCode(value);
  });
  out = out.replace(/&#x([0-9a-fA-F]+);/g, (match: string, code: string) => {
    const value = parseInt(code, 16);
    if (isNaN(value) || value <= 0 || value > 65535) {
      return '';
    }
    return String.fromCharCode(value);
  });
  return out;
}

/** 相对地址补全为 HTTPS 绝对地址；非法/内网/非 http(s) 一律拒绝。 */
/**
 * 正文里的相对链接绝对化 + 外部链接合法性判定。
 *
 * 安全策略不手写正则/前缀：scheme/host/账号信息全部交给平台 URL 解析器（utils/Security.parseWebUrl，
 * 内部用 @ohos.url）判断，只保留一条产品规则——不把本机回环地址（本地播放代理/调试端口）
 * 作为评论/正文学外链带出去。
 */
function absolutize(raw: string, base: string): string {
  const text = raw.trim();
  if (text.length === 0) {
    return '';
  }
  let absolute = text;
  if (absolute.startsWith('//')) {
    absolute = 'https:' + absolute;
  } else if (absolute.startsWith('/')) {
    absolute = base + absolute;
  }
  const parsed = parseWebUrl(absolute);
  if (parsed === null) {
    return '';
  }
  if (parsed.username.length > 0 || parsed.password.length > 0) {
    return '';
  }
  const host: string = parsed.hostname.toLowerCase();
  if (host === 'localhost' || host === '127.0.0.1' || host === '::1' || host === '[::1]') {
    return '';
  }
  return parsed.href;
}

function attrOf(tag: string, name: string): string {
  const key = name + '=';
  const at = tag.indexOf(key);
  if (at < 0) {
    return '';
  }
  let i = at + key.length;
  while (i < tag.length && tag.charAt(i) === ' ') {
    i++;
  }
  if (i >= tag.length) {
    return '';
  }
  const quote = tag.charAt(i);
  if (quote === '"' || quote === "'") {
    const end = tag.indexOf(quote, i + 1);
    return end < 0 ? '' : tag.substring(i + 1, end);
  }
  let end = i;
  while (end < tag.length && tag.charAt(end) !== ' ' && tag.charAt(end) !== '>') {
    end++;
  }
  return tag.substring(i, end);
}

function stripElement(html: string, tag: string): string {
  let out = html;
  let lower = out.toLowerCase();
  let guard = 0;
  while (guard < 200) {
    guard++;
    const start = lower.indexOf('<' + tag);
    if (start < 0) {
      break;
    }
    const openEnd = lower.indexOf('>', start);
    if (openEnd < 0) {
      out = out.substring(0, start);
      break;
    }
    const close = lower.indexOf('</' + tag, openEnd);
    if (close < 0) {
      out = out.substring(0, start);
      break;
    }
    const closeEnd = lower.indexOf('>', close);
    if (closeEnd < 0) {
      out = out.substring(0, start);
      break;
    }
    out = out.substring(0, start) + out.substring(closeEnd + 1);
    lower = out.toLowerCase();
  }
  return out;
}

function stripComments(html: string): string {
  let out = html;
  let guard = 0;
  while (guard < 200) {
    guard++;
    const start = out.indexOf('<!--');
    if (start < 0) {
      break;
    }
    const end = out.indexOf('-->', start + 4);
    if (end < 0) {
      out = out.substring(0, start);
      break;
    }
    out = out.substring(0, start) + out.substring(end + 3);
  }
  return out;
}

/**
 * 原生 HTML 子集解析器（白名单 p/br/h1-h4/strong/em/ul/ol/li/img/a/blockquote/hr）。
 * 不执行脚本、不加载 iframe/video；其余标签剥离但保留文本。禁止 Web/RichText。
 */
export class HgHtmlParser {
  private base: string = '';
  private blocks: HgBlock[] = [];
  private spans: HgInline[] = [];
  private list: HgBlock | null = null;
  private itemSpans: HgInline[] = [];
  private listKind: string = 'ul';
  private bold: number = 0;
  private italic: number = 0;
  private link: string = '';
  private quote: number = 0;

  static parse(html: string, base: string): HgBlock[] {
    const parser = new HgHtmlParser();
    parser.base = base;
    return parser.run(html);
  }

  private run(html: string): HgBlock[] {
    if (html === undefined || html === null || html.length === 0) {
      return [];
    }
    let text = stripComments(html);
    const stripTags: string[] = ['script', 'style', 'iframe', 'video', 'audio', 'svg', 'math', 'object', 'embed'];
    for (let i = 0; i < stripTags.length; i++) {
      text = stripElement(text, stripTags[i]);
    }
    if (text.indexOf('<') < 0) {
      this.parsePlain(text);
      return this.blocks;
    }
    let i = 0;
    let guard = 0;
    while (i < text.length && guard < 20000) {
      guard++;
      const lt = text.indexOf('<', i);
      if (lt < 0) {
        this.pushText(text.substring(i));
        break;
      }
      if (lt > i) {
        this.pushText(text.substring(i, lt));
      }
      const gt = text.indexOf('>', lt + 1);
      if (gt < 0) {
        this.pushText(text.substring(lt));
        break;
      }
      const rawTag = text.substring(lt + 1, gt).trim();
      this.handleTag(rawTag);
      i = gt + 1;
    }
    this.finish();
    return this.blocks;
  }

  private parsePlain(text: string): void {
    const lines = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (line.length === 0) {
        continue;
      }
      const block = new HgBlock();
      block.kind = 'p';
      const span = new HgInline();
      span.text = line;
      block.spans.push(span);
      this.blocks.push(block);
    }
  }

  private handleTag(rawTag: string): void {
    if (rawTag.length === 0 || rawTag.startsWith('!')) {
      return;
    }
    const closing = rawTag.startsWith('/');
    let body = closing ? rawTag.substring(1).trim() : rawTag;
    const selfClosing = body.endsWith('/');
    if (selfClosing) {
      body = body.substring(0, body.length - 1).trim();
    }
    const space = body.indexOf(' ');
    const name = (space < 0 ? body : body.substring(0, space)).toLowerCase();
    if (closing) {
      this.handleClose(name);
      return;
    }
    this.handleOpen(name, body);
  }

  private handleOpen(name: string, body: string): void {
    if (name === 'p' || name === 'div' || name === 'section' || name === 'article' ||
      name === 'header' || name === 'footer' || name === 'main' || name === 'figure' || name === 'figcaption') {
      this.flushSpans('p');
      return;
    }
    if (name === 'h1' || name === 'h2' || name === 'h3' || name === 'h4' || name === 'h5' || name === 'h6') {
      this.flushSpans('p');
      return;
    }
    if (name === 'ul') {
      this.flushSpans('p');
      this.startList('ul');
      return;
    }
    if (name === 'ol') {
      this.flushSpans('p');
      this.startList('ol');
      return;
    }
    if (name === 'li') {
      this.flushSpans('p');
      if (this.list === null) {
        this.startList(this.listKind);
      } else {
        this.flushItem();
      }
      return;
    }
    if (name === 'blockquote') {
      this.flushSpans('p');
      this.quote++;
      return;
    }
    if (name === 'br') {
      this.pushText('\n');
      return;
    }
    if (name === 'img') {
      this.flushSpans('p');
      this.closeList();
      this.pushImage(body);
      return;
    }
    if (name === 'hr') {
      this.flushSpans('p');
      this.closeList();
      const block = new HgBlock();
      block.kind = 'hr';
      this.blocks.push(block);
      return;
    }
    if (name === 'strong' || name === 'b') {
      this.bold++;
      return;
    }
    if (name === 'em' || name === 'i') {
      this.italic++;
      return;
    }
    if (name === 'a') {
      this.link = absolutize(attrOf(body, 'href'), this.base);
      return;
    }
  }

  private handleClose(name: string): void {
    if (name === 'p' || name === 'div' || name === 'section' || name === 'article' ||
      name === 'header' || name === 'footer' || name === 'main' || name === 'figure' || name === 'figcaption') {
      this.flushSpans(this.quote > 0 ? 'quote' : 'p');
      return;
    }
    if (name === 'h1' || name === 'h2' || name === 'h3' || name === 'h4' || name === 'h5' || name === 'h6') {
      this.flushSpans(name === 'h1' ? 'h1' : (name === 'h2' ? 'h2' : (name === 'h3' ? 'h3' : 'h4')));
      return;
    }
    if (name === 'ul' || name === 'ol') {
      this.closeList();
      return;
    }
    if (name === 'li') {
      this.flushItem();
      return;
    }
    if (name === 'blockquote') {
      this.flushSpans('quote');
      if (this.quote > 0) {
        this.quote--;
      }
      return;
    }
    if (name === 'strong' || name === 'b') {
      if (this.bold > 0) {
        this.bold--;
      }
      return;
    }
    if (name === 'em' || name === 'i') {
      if (this.italic > 0) {
        this.italic--;
      }
      return;
    }
    if (name === 'a') {
      this.link = '';
      return;
    }
  }

  private startList(kind: string): void {
    if (this.list !== null) {
      this.closeList();
    }
    const block = new HgBlock();
    block.kind = kind;
    this.list = block;
    this.listKind = kind;
  }

  private flushItem(): void {
    if (this.list === null) {
      this.itemSpans = [];
      return;
    }
    if (this.itemSpans.length > 0) {
      this.trimSpans(this.itemSpans);
      if (this.itemSpans.length > 0) {
        this.list.items.push(this.itemSpans);
      }
    }
    this.itemSpans = [];
  }

  private closeList(): void {
    this.flushItem();
    if (this.list !== null && this.list.items.length > 0) {
      this.blocks.push(this.list);
    }
    this.list = null;
    this.listKind = 'ul';
  }

  private pushImage(body: string): void {
    let src = attrOf(body, 'data-src');
    if (src.length === 0) {
      src = attrOf(body, 'data-original');
    }
    if (src.length === 0) {
      src = attrOf(body, 'data-lazy-src');
    }
    if (src.length === 0) {
      src = attrOf(body, 'src');
    }
    const url = absolutize(src, this.base);
    if (url.length === 0) {
      return;
    }
    const block = new HgBlock();
    block.kind = 'img';
    block.src = url;
    block.alt = attrOf(body, 'alt');
    const width = Number(attrOf(body, 'width'));
    const height = Number(attrOf(body, 'height'));
    if (!isNaN(width) && !isNaN(height) && width > 0 && height > 0) {
      let ratio = height / width;
      if (ratio < 0.5) {
        ratio = 0.5;
      }
      if (ratio > 2.4) {
        ratio = 2.4;
      }
      block.ratio = ratio;
    }
    this.blocks.push(block);
  }

  private pushText(raw: string): void {
    const decoded = decodeEntities(raw);
    if (decoded.length === 0) {
      return;
    }
    const normalized = this.normalize(decoded);
    if (normalized.length === 0) {
      return;
    }
    const span = new HgInline();
    span.text = normalized;
    span.bold = this.bold > 0;
    span.italic = this.italic > 0;
    span.link = this.link;
    const target: HgInline[] = this.list !== null ? this.itemSpans : this.spans;
    if (target.length > 0) {
      const last = target[target.length - 1];
      if (last.bold === span.bold && last.italic === span.italic && last.link === span.link) {
        last.text = last.text + span.text;
        return;
      }
    }
    target.push(span);
  }

  private normalize(raw: string): string {
    const parts = raw.split('\n');
    const out: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const compact = parts[i].replace(/\s+/g, ' ');
      out.push(compact);
    }
    let joined = '';
    for (let i = 0; i < out.length; i++) {
      if (i > 0) {
        joined += '\n';
      }
      joined += out[i];
    }
    if (this.spans.length === 0 && this.itemSpans.length === 0) {
      joined = joined.replace(/^\s+/, '');
    }
    return joined;
  }

  private trimSpans(list: HgInline[]): void {
    if (list.length === 0) {
      return;
    }
    const first = list[0];
    first.text = first.text.replace(/^\s+/, '');
    const last = list[list.length - 1];
    last.text = last.text.replace(/\s+$/, '');
    let i = list.length - 1;
    while (i >= 0) {
      if (list[i].text.length === 0) {
        list.splice(i, 1);
      }
      i--;
    }
  }

  private flushSpans(kind: string): void {
    if (this.spans.length === 0) {
      return;
    }
    this.trimSpans(this.spans);
    if (this.spans.length === 0) {
      this.spans = [];
      return;
    }
    const block = new HgBlock();
    block.kind = kind;
    block.spans = this.spans;
    this.collectLinks(block);
    this.blocks.push(block);
    this.spans = [];
  }

  private collectLinks(block: HgBlock): void {
    for (let i = 0; i < block.spans.length; i++) {
      const link = block.spans[i].link;
      if (link.length > 0 && block.links.indexOf(link) < 0) {
        block.links.push(link);
      }
    }
  }

  private finish(): void {
    this.flushItem();
    this.closeList();
    this.flushSpans(this.quote > 0 ? 'quote' : 'p');
    this.trimSpans(this.spans);
  }
}

/** 原生极简富文本渲染：段落/标题/列表/引用/图片/链接，全部走原生组件。 */
@Component
export struct PostContent {
  @Prop @Watch('onContentChanged') content: string = '';
  @Prop dark: boolean = true;
  @State blocks: HgBlock[] = [];

  aboutToAppear(): void {
    this.rebuild();
  }

  onContentChanged(): void {
    this.rebuild();
  }

  private rebuild(): void {
    this.blocks = HgHtmlParser.parse(this.content, Api.lineBase());
  }

  private headingSize(kind: string): number {
    if (kind === 'h1') {
      return HgFont.pageTitle;
    }
    if (kind === 'h2') {
      return HgFont.section;
    }
    if (kind === 'h3') {
      return HgFont.cardTitle;
    }
    return HgFont.body;
  }

  @Builder
  RichText(block: HgBlock, size: number, lineHeight: number, forceBold: boolean) {
    Text() {
      ForEach(block.spans, (span: HgInline, index: number) => {
        Span(span.text)
          .fontSize(size)
          .fontColor(span.link.length > 0 ? HgColor.accent(this.dark) : HgColor.textPrimary(this.dark))
          .fontWeight(forceBold || span.bold ? HgFont.weightBold : HgFont.weightRegular)
          .fontStyle(span.italic ? FontStyle.Italic : FontStyle.Normal)
          .lineHeight(lineHeight)
          .decoration(span.link.length > 0
            ? { type: TextDecorationType.Underline, color: HgColor.accent(this.dark) }
            : { type: TextDecorationType.None })
      }, (span: HgInline, index: number) => 'span-' + index)
    }
    .width('100%')
    .lineHeight(lineHeight)
  }

  @Builder
  LinkChips(block: HgBlock) {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(block.links, (link: string, index: number) => {
        Row({ space: HgSpace.xs }) {
          SymbolGlyph($r('sys.symbol.arrowshape_turn_up_right'))
            .fontSize(HgIconSize.inline)
            .fontColor([HgColor.accent(this.dark)])
          Text('打开链接 ' + (index + 1).toString())
            .fontSize(HgFont.caption)
            .fontColor(HgColor.accent(this.dark))
            .maxLines(1)
        }
        .height(32)
        .padding({ left: HgSpace.m, right: HgSpace.m })
        .backgroundColor(HgColor.accentSoft(this.dark))
        .borderRadius(HgRadius.chip)
        .margin({ right: HgSpace.s, top: HgSpace.xs })
        .onClick(() => {
          Api.openUrl(link);
        })
      }, (link: string) => link)
    }
    .width('100%')
  }

  @Builder
  BlockView(block: HgBlock) {
    if (block.kind === 'p') {
      this.RichText(block, HgFont.body, HgFont.lineBody + 2, false)
      if (block.links.length > 0) {
        this.LinkChips(block)
      }
    } else if (block.kind === 'h1' || block.kind === 'h2' || block.kind === 'h3' || block.kind === 'h4') {
      this.RichText(block, this.headingSize(block.kind), this.headingSize(block.kind) + 8, true)
      if (block.links.length > 0) {
        this.LinkChips(block)
      }
    } else if (block.kind === 'quote') {
      Column({ space: HgSpace.xs }) {
        this.RichText(block, HgFont.secondary, HgFont.lineSecondary + 2, false)
        if (block.links.length > 0) {
          this.LinkChips(block)
        }
      }
      .width('100%')
      .padding({ left: HgSpace.m, right: HgSpace.m, top: HgSpace.s, bottom: HgSpace.s })
      .backgroundColor(HgColor.surface2(this.dark))
      .borderRadius(HgRadius.inline)
      .border({ width: { left: 3 }, color: HgColor.accent(this.dark) })
    } else if (block.kind === 'ul' || block.kind === 'ol') {
      Column({ space: HgSpace.xs }) {
        ForEach(block.items, (item: HgInline[], index: number) => {
          Row({ space: HgSpace.xs }) {
            Text(block.kind === 'ol' ? (index + 1).toString() + '.' : '•')
              .width(20)
              .fontSize(HgFont.body)
              .fontColor(HgColor.textTertiary(this.dark))
            Text() {
              ForEach(item, (span: HgInline, spanIndex: number) => {
                Span(span.text)
                  .fontSize(HgFont.body)
                  .fontColor(span.link.length > 0 ? HgColor.accent(this.dark) : HgColor.textPrimary(this.dark))
                  .fontWeight(span.bold ? HgFont.weightBold : HgFont.weightRegular)
                  .fontStyle(span.italic ? FontStyle.Italic : FontStyle.Normal)
              }, (span: HgInline, spanIndex: number) => 'li-span-' + spanIndex)
            }
            .layoutWeight(1)
            .lineHeight(HgFont.lineBody + 2)
          }
          .width('100%')
          .alignItems(VerticalAlign.Top)
          .onClick(() => {
            for (let i = 0; i < item.length; i++) {
              if (item[i].link.length > 0) {
                Api.openUrl(item[i].link);
                return;
              }
            }
          })
        }, (item: HgInline[], index: number) => 'li-' + index)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    } else if (block.kind === 'img') {
      Stack() {
        HgAsyncCover({
          url: block.src,
          dark: this.dark,
          radius: 0,
          coverWidth: '100%',
          coverHeight: '100%'
        })
      }
      .width('100%')
      .aspectRatio(block.ratio > 0 ? 1 / block.ratio : 16 / 9)
      .borderRadius(HgRadius.row)
      .clip(true)
    } else if (block.kind === 'hr') {
      Divider()
        .width('100%')
        .strokeWidth(0.5)
        .color(HgColor.hairline(this.dark))
        .margin({ top: HgSpace.s, bottom: HgSpace.s })
    }
  }

  build() {
    Column({ space: HgSpace.m }) {
      ForEach(this.blocks, (block: HgBlock, index: number) => {
        this.BlockView(block)
      }, (block: HgBlock, index: number) => 'block-' + index + '-' + block.kind)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }
}
