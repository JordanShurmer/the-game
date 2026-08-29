// Play the page in a headless browser, and take pictures of it.
//
//     make web
//     node tools/play_web.mjs shots/web 844 390
//
// `bin/shot` is how to look at the world. This is how to look at the
// page: it loads web/build, presses play, holds a thumb on the pad and
// on JUMP the way a hand would, and writes a PNG at each step --
// <prefix>-idle, -walk, -jump, -after. Everything the page says goes to
// the terminal, which is where a shader that will not compile in the
// browser turns up.
//
// It needs node and playwright, which are not part of the game's
// toolchain:
//
//     npm install playwright http-server && npx playwright install chromium
//
// The touch positions are shares of the canvas, so the size of the
// window does not change what is touched. Give a phone's size to see
// what a phone sees; the canvas keeps the shape the game draws in and
// the page puts bars beside it.
import { chromium } from 'playwright';
import { createServer } from 'http-server';

const prefix = process.argv[2] || 'shots/web';
const width = Number(process.argv[3] || 844);
const height = Number(process.argv[4] || 390);
const root = 'web/build';
const port = 8765;

const server = createServer({ root, cache: -1 });
await new Promise(ready => server.listen(port, ready));

// Software rendering, because a headless machine has no GPU. It draws
// the right picture and draws it slowly: the page is a few frames a
// second here and that says nothing about a phone.
const browser = await chromium.launch({
	args: ['--use-gl=angle', '--use-angle=swiftshader', '--enable-unsafe-swiftshader', '--no-sandbox'],
});
const context = await browser.newContext({
	viewport: { width, height },
	hasTouch: true,
	isMobile: true,
});
const page = await context.newPage();
page.on('console', message => console.log(message.text()));
page.on('pageerror', error => console.log('page error:', error.message));

await page.goto(`http://127.0.0.1:${port}/index.html`);
await page.waitForFunction(() => !document.getElementById('play').disabled, null, { timeout: 300000 });
await page.click('#play');
await page.waitForTimeout(3000);

async function touch(kind, points) {
	await page.evaluate(([kind, points]) => {
		const canvas = document.getElementById('canvas');
		const box = canvas.getBoundingClientRect();
		const list = points.map((p, i) => new Touch({
			identifier: i,
			target: canvas,
			clientX: box.left + p[0] * box.width,
			clientY: box.top + p[1] * box.height,
		}));
		canvas.dispatchEvent(new TouchEvent(kind, {
			touches: list, targetTouches: list, changedTouches: list,
			bubbles: true, cancelable: true,
		}));
	}, [kind, points]);
}

async function shot(name) {
	await page.screenshot({ path: `${prefix}-${name}.png` });
	console.log(`${prefix}-${name}.png`);
}

const PAD = [0.20, 0.76];  // the right of the thumb pad: walk
const JUMP = [0.90, 0.80]; // the jump button

await shot('idle');

await touch('touchstart', [PAD]);
await page.waitForTimeout(1500);
await shot('walk');

await touch('touchstart', [PAD, JUMP]);
await page.waitForTimeout(600);
await shot('jump');

await touch('touchend', []);
await page.waitForTimeout(1200);
await shot('after');

await browser.close();
server.close();
process.exit(0);
