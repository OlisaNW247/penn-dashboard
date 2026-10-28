-- course_documents.collector gains 'server' (2026-10-27): the rows
-- discover-websites writes from a course's own website. They used to take
-- the column's default, 'phone', so a phone's complete-set report that had
-- not yet downloaded a fresh crawl retired it (ECON 0100, 2026-10-26: five
-- website rows fetched at 14:33 UTC, marked gone at 14:54). No client
-- report retires a 'server' row any more (sync's
-- selectLiveDocumentIDsForCourse); the crawl retires its own.
alter table public.course_documents drop constraint if exists course_documents_collector_check;
alter table public.course_documents add constraint course_documents_collector_check
  check (collector in ('phone', 'extension', 'server'));

-- Every existing website row came from the crawl: no client uploads that
-- kind. Gone ones are restamped too, so the column says who wrote each row.
update public.course_documents set collector = 'server' where kind = 'website';
