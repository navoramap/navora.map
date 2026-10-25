const assert = require('node:assert/strict');
const test = require('node:test');
const { deleteAllPublicChatMessages } = require('./public_chat_moderation');

test('deletes all public chat messages in Firestore-sized batches', async () => {
  const deletedIds = [];
  const pages = [
    [{ id: 'message-1' }, { id: 'message-2' }],
    [{ id: 'message-3' }],
    [],
  ];
  const db = {
    collection(name) {
      assert.equal(name, 'public_chat_messages');
      return {
        limit(pageSize) {
          assert.equal(pageSize, 450);
          return {
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

  const deletedCount = await deleteAllPublicChatMessages(db);

  assert.equal(deletedCount, 3);
  assert.deepEqual(deletedIds, ['message-1', 'message-2', 'message-3']);
});

test('rejects batch sizes outside Firestore limits', async () => {
  await assert.rejects(
    deleteAllPublicChatMessages({}, 501),
    RangeError,
  );
});
