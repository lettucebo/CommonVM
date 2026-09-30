-- Same predicate as HedgeDoc 1.12.0 Revision.saveAllNotesRevision.
SELECT id, "createdAt", "lastchangeAt", "savedAt"
  FROM "Notes"
 WHERE ("lastchangeAt" IS NULL OR "lastchangeAt" > "createdAt")
   AND ("savedAt" IS NULL OR "savedAt" < "lastchangeAt")
 ORDER BY id;
