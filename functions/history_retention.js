async function deleteExpiredUserHistory(
    db,
    collectionName,
    cutoff,
    pageSize = 100,
) {
  let deleted = 0;
  while (true) {
    const snapshot = await db
        .collectionGroup(collectionName)
        .where('expires_at', '<=', cutoff)
        .orderBy('expires_at')
        .limit(pageSize)
        .get();
    if (snapshot.empty) return deleted;

    const batch = db.batch();
    for (const document of snapshot.docs) batch.delete(document.ref);
    await batch.commit();
    deleted += snapshot.size;
  }
}

module.exports = { deleteExpiredUserHistory };
