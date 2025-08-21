# Update this monthly.
DECLARE QUERY_DATE DATE DEFAULT '2025-07-01';

# Add/edit platforms in alphabetical order here.
DECLARE PLATFORMS ARRAY<STRUCT<regex STRING, name STRING>> DEFAULT [
  ('awex', '000webhost'),
  ('akamai', 'Akamai'),
  ('x-ak-protocol', 'Akamai'),
  ('x-ah-environment', 'Acquia'),
  ('alproxy', 'AlwaysData'),
  ('automattic.com/work-with-us', 'Automattic'),
  ('wpvip.com/careers', 'Automattic'),
  ('wordpress.com', 'Automattic'),
  ('a9130478a60e5f9135f765b23f26593b', 'Automattic'),
  ('x-azure-ref', 'Azure'),
  ('X-MSEdge-Ref', 'Azure'),
  ('cf-ray', 'Cloudflare'),
  ('x-amz-cf-id', 'AWS CloudFront'),
  ('flywheel', 'Flywheel'),
  ('framer/', 'Framer'),
  ('fly-request-id', 'Fly.io'),
  ('x-github-request', 'GitHub Pages'),
  ('dps/', 'GoDaddy Website Builder'),
  ('hostinger', 'Hostinger'),
  ('zyro.com', 'Hostinger Website Builder'),
  ('hubspot', 'HubSpot'),
  ('x-kinsta-cache', 'Kinsta'),
  ('x-lw-cache', 'Liquid Web'),
  ('netlify', 'Netlify'),
  ('x-opennext', 'OpenNext'),
  ('x-pantheon-styx-hostname', 'Pantheon'),
  ('seravo', 'Seravo'),
  ('x-shopify-stage', 'Shopify'),
  ('shopify', 'Shopify'),
  ('b7440e60b07ee7b8044761568fab26e8', 'SiteGround'),
  ('624d5be7be38418a3e2a818cc8b7029b', 'SiteGround'),
  ('6b7412fb82ca5edfd0917e3957f05d89', 'SiteGround'),
  ('squarespace', 'Squarespace'),
  ('x-vercel-id', 'Vercel'),
  ('web1', 'Web1'),
  ('weebly', 'Weebly'),
  ('x-wix-request-id', 'Wix'),
  ('wp-cloud', 'WP-Cloud'),
  ('wpe-backend', 'WP Engine'),
  ('wp engine atlas', 'WP Engine Atlas'),
  ('wp engine', 'WP Engine'),
  ('zoneos', 'Zone.eu')
];

WITH crux AS (
  SELECT
    IF(device = 'desktop', 'desktop', 'mobile') AS client,
    CONCAT(origin, '/') AS url,
    CASE
      WHEN SAFE_DIVIDE(fast_ttfb, (fast_ttfb + avg_ttfb + slow_ttfb)) >= 0.75 THEN 'Good'
      WHEN SAFE_DIVIDE(slow_ttfb, (fast_ttfb + avg_ttfb + slow_ttfb)) >= 0.25 THEN 'Poor'
      WHEN fast_ttfb IS NOT NULL THEN 'Needs Improvement'
      ELSE NULL
    END AS ttfb
  FROM
    `chrome-ux-report.materialized.device_summary`
  WHERE
    date = QUERY_DATE AND
    device IN ('desktop', 'phone') AND
    fast_ttfb IS NOT NULL
),

requests AS (
  SELECT
    r.client,
    r.root_page,
    -- all headers except the ones broken out below (name:value)
    STRING_AGG(
      IF(LOWER(h.name) NOT IN ('x-powered-by','via','server'),
         CONCAT(h.name, ':', IFNULL(h.value,'')),
         NULL
      ),
      ' || '
    ) AS respOtherHeaders,
    -- specific headers as separate fields
    STRING_AGG(IF(LOWER(h.name)='x-powered-by', h.value, NULL), ' || ') AS resp_x_powered_by,
    STRING_AGG(IF(LOWER(h.name)='via',         h.value, NULL), ' || ') AS resp_via,
    STRING_AGG(IF(LOWER(h.name)='server',      h.value, NULL), ' || ') AS resp_server
  FROM
    `httparchive.crawl.requests` AS r,
    UNNEST(r.response_headers) AS h
  WHERE
    r.date = QUERY_DATE
    AND r.is_main_document
  GROUP BY
    r.client, r.root_page
),

platform_regex AS (
  SELECT
    STRING_AGG(
      REGEXP_REPLACE(regex, r'([\.\*\+\?\|\(\)\[\]\{\}\^\$])', r'\\\1'),
      r'|'
    ) AS pattern
  FROM UNNEST(PLATFORMS)
),

detected_platforms AS (
  WITH m AS (
    SELECT
      client,
      root_page AS url,
      ARRAY_CONCAT(
        REGEXP_EXTRACT_ALL(LOWER(respOtherHeaders), (SELECT pattern FROM platform_regex)),
        REGEXP_EXTRACT_ALL(LOWER(IFNULL(resp_x_powered_by, '')), (SELECT pattern FROM platform_regex)),
        REGEXP_EXTRACT_ALL(LOWER(IFNULL(resp_via, '')), (SELECT pattern FROM platform_regex)),
        REGEXP_EXTRACT_ALL(LOWER(IFNULL(resp_server, '')), (SELECT pattern FROM platform_regex))
      ) AS matches
    FROM requests
  )
  SELECT
    m.client,
    m.url,
    p.name AS platform
  FROM m
  CROSS JOIN UNNEST(m.matches) AS match
  JOIN UNNEST(PLATFORMS) AS p
    ON LOWER(p.regex) = match
),

url_platforms AS (
  SELECT
    client,
    url,
    ARRAY_AGG(DISTINCT platform ORDER BY platform) as platform_array
  FROM detected_platforms
  GROUP BY client, url
)

SELECT
  TO_JSON_STRING(platform_array) as platform,
  client,
  COUNT(DISTINCT url) AS n,
  COUNT(DISTINCT IF(ttfb = 'Good', url, NULL)) / COUNT(DISTINCT url) AS fast,
  COUNT(DISTINCT IF(ttfb = 'Needs Improvement', url, NULL)) / COUNT(DISTINCT url) AS avg,
  COUNT(DISTINCT IF(ttfb = 'Poor', url, NULL)) / COUNT(DISTINCT url) AS slow
FROM
  url_platforms
JOIN
  crux
USING
  (client, url)
GROUP BY
  platform_array,
  client
HAVING n >= 100
ORDER BY
  fast DESC
