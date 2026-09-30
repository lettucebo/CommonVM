\pset format unaligned
\pset tuples_only on
WITH n AS (
  SELECT id, shortid, alias,
         rtrim(translate(encode(decode(replace(id::text,'-',''),'hex'),'base64'),'+/','-_'),'=') AS enc
    FROM "Notes"
)
SELECT path FROM (
  SELECT '/' || enc AS path FROM n
  UNION ALL SELECT '/' || shortid FROM n
  UNION ALL SELECT '/' || alias FROM n WHERE alias IS NOT NULL AND alias <> ''
  UNION ALL SELECT '/s/' || shortid FROM n
  UNION ALL SELECT '/s/' || alias FROM n WHERE alias IS NOT NULL AND alias <> ''
  UNION ALL SELECT '/p/' || shortid FROM n
  UNION ALL SELECT '/p/' || alias FROM n WHERE alias IS NOT NULL AND alias <> ''
  UNION ALL SELECT '/' || enc || '/' || action FROM n,
    unnest(ARRAY['publish','slide','download','info','revision','pdf','pandoc']) AS action
  UNION ALL SELECT '/s/' || shortid || '/' || action FROM n,
    unnest(ARRAY['download','edit']) AS action
  UNION ALL SELECT '/p/' || shortid || '/edit' FROM n
  UNION ALL SELECT '/' || n.enc || '/revision/' ||
    (extract(epoch FROM r."createdAt") * 1000)::bigint
    FROM n JOIN "Revisions" r ON r."noteId" = n.id
) AS paths ORDER BY path;
