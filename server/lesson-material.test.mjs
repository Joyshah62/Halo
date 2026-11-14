import { test } from 'node:test';
import assert from 'node:assert/strict';
import { anchorQuote, buildMaterial, cleanScene } from './lesson-material.js';
import { cleanStep } from './steps.js';
const pages = [{ page: 12, text: 'The membrane controls exchange.\n\nWater moves across the membrane by osmosis.' }, { page: 13, text: 'An example of a cell in fresh water.' }];
const concept = { n: 1, name: 'osmosis', why: 'Understand how cells exchange water', page: 12 };
const raw = { quote: 'Water moves across the membrane by osmosis.', headline: 'Follow the water', visual: { kind: 'flow', title: 'Water exchange', nodes: [{ label: 'Outside', detail: 'Water around the cell' }, { label: 'Membrane', detail: 'The boundary' }], caption: 'Track the movement across the boundary.' }, example: { title: 'A cell in water', given: 'A cell in fresh water', steps: ['Compare the two sides'], result: 'Identify the movement', why: 'Use the membrane as the boundary.' } };
const input = { concept, pages, title: 'Biology', mock: false };

test('textbook anchor is verified against a real supplied page', () => {
  assert.deepEqual(anchorQuote(raw.quote, pages, concept), { page: 12, quote: raw.quote });
  assert.equal(anchorQuote('An example of a cell in fresh water.', pages, concept).page, 13);
  const fallback = anchorQuote('A fabricated quotation about cells.', pages, concept);
  assert.notEqual(fallback.quote, 'A fabricated quotation about cells.');
  assert.ok(pages.some((p) => p.page === fallback.page && p.text.includes(fallback.quote)));
});
test('scene bounds and unknown presentation modes are sanitized', () => {
  const scene = cleanScene({ ...raw, visual: { kind: 'script', nodes: Array.from({ length: 12 }, () => ({ label: 'a'.repeat(100), detail: 'b'.repeat(500) })) } }, pages, concept);
  assert.equal(scene.visual.kind, 'flow');
  assert.equal(scene.visual.nodes.length, 4);
  assert.equal(scene.visual.nodes[0].label.length, 45);
  assert.equal(cleanStep({ say: 'Watch this', focus: 'visual' }).focus, 'visual');
  assert.equal(cleanStep({ say: 'Watch this', focus: 'arbitrary' }).focus, undefined);
});
test('source appears before research; only cited HTTPS evidence and credited images survive', async () => {
  const events = [];
  const out = await buildMaterial(input, (data) => events.push(data), {
    generate: async () => raw,
    search: async () => ({ sections: [{ heading: 'An example', text: 'A supplementary explanation.', cites: [1, 2] }], sources: [{ title: 'Biology', site: 'example.edu', url: 'https://example.edu/biology' }, { title: 'Bad', site: 'bad', url: 'javascript:alert(1)' }] }),
    images: async () => [{ thumb: 'https://upload.wikimedia.org/picture.png', page: 'https://commons.wikimedia.org/wiki/File:Picture', title: 'Cell', credit: 'Artist', license: 'CC BY' }, { thumb: 'file:///private/photo', page: 'https://example.edu', title: 'Bad' }],
  });
  assert.equal(events[0].status, 'searching');
  assert.ok(events[0].anchor.quote);
  assert.equal(out.status, 'ready');
  assert.equal(out.web.sources.length, 1);
  assert.equal(out.images.length, 1);
  assert.equal(out.images[0].license, 'CC BY');
  assert.equal(out.anchor.quote, raw.quote);
});
test('research failures and ungrounded prose never block or masquerade as web evidence', async () => {
  for (const search of [async () => { throw new Error('offline'); }, async () => ({ sources: [], sections: [{ text: 'No citations', cites: [] }] })]) {
    const out = await buildMaterial(input, () => {}, { generate: async () => raw, search, images: async () => { throw new Error('offline'); } });
    assert.equal(out.status, 'unavailable');
    assert.equal(out.web, null);
    assert.deepEqual(out.images, []);
    assert.equal(out.example.result, raw.example.result);
  }
});
test('scene-generation failure keeps an honest textbook anchor and usable research', async () => {
  const out = await buildMaterial(input, () => {}, { generate: async () => { throw new Error('model unavailable'); }, search: async () => null, images: async () => [] });
  assert.ok(out.anchor.quote);
  assert.equal(out.visual.nodes.length, 0);
  assert.equal(out.status, 'unavailable');
});

test('uploaded textbook copies and video pages are not used as reading evidence', async () => {
  const out = await buildMaterial(input, () => {}, {
    generate: async () => raw,
    search: async () => ({ sections: [{ heading: 'Copy', text: 'Uploaded passage', cites: [1] }], sources: [{ title: 'Uploaded book', site: 'scribd.com', url: 'https://www.scribd.com/document/book' }] }),
    images: async () => [],
  });
  assert.equal(out.web, null);
  assert.equal(out.status, 'unavailable');
});
