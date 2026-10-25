async function deleteAllPublicChatMessages(db, pageSize = 450) {
  if (!Number.isSafeInteger(pageSize) || pageSize < 1 || pageSize > 500) {
    throw new RangeError('A valid Firestore batch page size is required.');
  }

  let deletedCount = 0;
  while (true) {
    const snapshot = await db
        .collection('public_chat_messages')
        .limit(pageSize)
        .get();
    if (snapshot.empty) return deletedCount;

    const batch = db.batch();
    for (const document of snapshot.docs) batch.delete(document.ref);
    await batch.commit();
    deletedCount += snapshot.size;
  }
}

module.exports = { deleteAllPublicChatMessages };
