// Render the checked-in, original Proximus SVG artwork. Generated assets are committed.
// Usage: node scripts/brand-assets.mjs /absolute/path/to/node_modules/sharp
import { createRequire } from 'node:module';
import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
const require = createRequire(import.meta.url);
const sharp = require(process.argv[2] || resolve('.local/brand-render/node_modules/sharp'));
const mark = (await readFile('apps/Brand/proximus_wings_flat.svg', 'utf8')).replace('fill="#23262b"', 'fill="#97FCE4"');
const appIcon = (mac) => Buffer.from(`<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024"><rect x="${mac ? 64 : 0}" y="${mac ? 64 : 0}" width="${mac ? 896 : 1024}" height="${mac ? 896 : 1024}" rx="${mac ? 190 : 0}" fill="#072723"/>${mark.replace('<svg ', '<svg x="192" y="216" width="640" height="592" ')}</svg>`);
const directory = 'apps/Assets.xcassets/AppIcon.appiconset';
await mkdir(directory, {recursive:true});
await mkdir('apps/iOSIcons', {recursive:true});
const images = [];
for (const size of [16,32,128,256,512]) for (const scale of [1,2]) {
  const filename = `mac-${size}-${scale}.png`;
  await sharp(appIcon(true)).resize(size*scale,size*scale).png().toFile(`${directory}/${filename}`);
  images.push({idiom:'mac',size:`${size}x${size}`,scale:`${scale}x`,filename});
}
await sharp(appIcon(false)).png().toFile(`${directory}/ios-1024.png`);
images.push({idiom:'universal',platform:'ios',size:'1024x1024',filename:'ios-1024.png'});
for (const [size,scale] of [[60,2],[60,3],[76,1],[76,2],[83.5,2],[20,2],[20,3],[29,2],[29,3],[40,2],[40,3]]) {
  await sharp(appIcon(false)).resize(size*scale,size*scale).png().toFile(`apps/iOSIcons/AppIcon${size}x${size}@${scale}x.png`);
}
await sharp(Buffer.from(await readFile('apps/Brand/proximus_wings_flat.svg'))).resize(530,490).png().toFile('apps/Brand/ProximusWings.png');
await writeFile(`${directory}/Contents.json`,JSON.stringify({images,info:{author:'xcode',version:1}},null,2)+'\n');
await writeFile('apps/Assets.xcassets/Contents.json',JSON.stringify({info:{author:'xcode',version:1}},null,2)+'\n');
