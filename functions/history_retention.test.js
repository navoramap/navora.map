const assert = require('node:assert/strict');
const test = require('node:test');
const { deleteExpiredUserHistory } = require('./history_retention');

test('deletes expired user-history documents in pages', async () => {
  const deletedIds = [];
  const pages = [
    [{ id: 'drive-1' }, { id: 'drive-2' }],
    [{ id: 'drive-3' }],
    [],
  ];
  const cutoff = new Date('2026-01-31T00:00:00.000Z');
  const db = {
    collectionGroup(name) {
      assert.equal(name, 'driving_history');
      return {
        where(field, operator, value) {
          assert.equal(field, 'expires_at');
          assert.equal(operator, '<=');
          assert.equal(value, cutoff);
          return this;
        },
        orderBy(field) {
          assert.equal(field, 'expires_at');
          return this;
        },
        limit(value) {
          assert.equal(value, 100);
          return this;
        },
        async get() {
          const docs = pages.shift();
          return {
            docs: docs.map((doc) => ({ ref: doc, id: doc.id })),
            empty: docs.length === 0,
            size: docs.length,
          };
        },
      };
    },
    batch() {
      return {
        delete(reference) {
          deletedIds.push(reference.id);
        },
        async commit() {},
      };
    },
  };

  const deleted = await deleteExpiredUserHistory(
      db,
      'driving_history',
      cutoff,
  );

  assert.equal(deleted, 3);
  assert.deepEqual(deletedIds, ['drive-1', 'drive-2', 'drive-3']);
});
