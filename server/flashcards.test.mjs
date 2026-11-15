import { test } from 'node:test';
import assert from 'node:assert/strict';
import { cardCount, cleanFlashcards, mockFlashcards } from './notes-quiz.js';
import { buildFlashcardsText, FLASHCARDS_SYSTEM } from './prompt.js';

test('flash cards: complete cards only, repeated fronts dropped, text clipped', () => {
  const deck = cleanFlashcards({ title: 'Cells', cards: [
    { front: 'What does the nucleus hold?', back: 'Most of the cell’s DNA.', hint: 'think genes', source: 'nucleus holds DNA' },
    { front: 'what does the NUCLEUS hold', back: 'duplicate' },
    { front: '', back: 'no front' },
    { front: 'No back' },
    { front: 'What do mitochondria make?', back: 'ATP: usable energy.' },
    { front: 'Why is the membrane selective?', back: 'x'.repeat(400) },
  ] });
  assert.equal(deck.title, 'Cells');
  assert.deepEqual(deck.cards.map((c) => c.front), ['What does the nucleus hold?', 'What do mitochondria make?', 'Why is the membrane selective?']);
  assert.equal(deck.cards[2].back.length, 280);
  assert.equal(deck.cards[1].hint, '');
});

test('flash cards: too few usable cards is an error the student can act on', () => {
  assert.throws(() => cleanFlashcards({ cards: [{ front: 'a', back: 'b' }] }), /Add a little more/);
  assert.throws(() => cleanFlashcards(null));
});

test('flash cards: deck size follows how much was written', () => {
  const short = [{ title: '', text: 'one two three' }];
  const long = [{ title: '', text: 'word '.repeat(2000) }];
  assert.equal(cardCount(short), 6);
  assert.equal(cardCount(long), 14);
});

test('flash cards: offline deck turns "term: meaning" lines into cards', () => {
  const deck = cleanFlashcards(mockFlashcards([{ title: 'Calc', text: 'Chain rule: outside′ × inside′\nPower rule → bring the power down\nalways ask what is inside' }]));
  assert.equal(deck.cards[0].front, 'What is Chain rule?');
  assert.equal(deck.cards[0].back, 'outside′ × inside′');
  assert.equal(deck.cards.length, 3);
});

test('flash card prompt carries the notes and the count', () => {
  const text = buildFlashcardsText({ notes: [{ title: 'Cells', text: 'nucleus holds DNA' }], document: 'Bio 101', count: 6 });
  assert.match(text, /Write 6 cards/);
  assert.match(text, /nucleus holds DNA/);
  assert.match(FLASHCARDS_SYSTEM, /"front"/);
});
