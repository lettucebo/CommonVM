\pset format unaligned
\pset tuples_only on
\pset fieldsep '\t'
SELECT 'N', id, shortid, coalesce(alias,''), permission, coalesce("ownerId"::text,''),
       md5(coalesce(title,'')), md5(coalesce(content,'')), md5(coalesce(authorship,'')),
       coalesce("lastchangeAt"::text,'')
  FROM "Notes" ORDER BY id;
SELECT 'R', id, "noteId", md5(coalesce(patch,'')), md5(coalesce("lastContent",'')),
       md5(coalesce(content,'')), coalesce(length::text,''), md5(coalesce(authorship,'')), "createdAt"
  FROM "Revisions" ORDER BY id;
SELECT 'U', id, profileid, md5(coalesce(profile,'')), md5(coalesce(history,''))
  FROM "Users" ORDER BY id;
SELECT 'A', id, "noteId", coalesce("userId"::text,''), color
  FROM "Authors" ORDER BY id;
