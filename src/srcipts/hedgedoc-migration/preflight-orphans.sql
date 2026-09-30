SELECT 'orphan_notes' AS kind, count(*) AS rows FROM "Notes" n
 WHERE n."ownerId" IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM "Users" u WHERE u.id = n."ownerId")
UNION ALL
SELECT 'orphan_author_user', count(*) FROM "Authors" a
 WHERE a."userId" IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM "Users" u WHERE u.id = a."userId")
UNION ALL
SELECT 'orphan_author_note', count(*) FROM "Authors" a
 WHERE a."noteId" IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM "Notes" n WHERE n.id = a."noteId")
UNION ALL
SELECT 'orphan_revisions', count(*) FROM "Revisions" r
 WHERE r."noteId" IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM "Notes" n WHERE n.id = r."noteId");
