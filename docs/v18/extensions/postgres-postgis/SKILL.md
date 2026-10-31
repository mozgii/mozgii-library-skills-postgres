---
name: postgres-postgis
description: 'Stores and queries geographic data in PostgreSQL with PostGIS: geometry versus geography, SRIDs (4326, 3857, local projections), points from latitude and longitude, GiST indexes, "within 5 km" with ST_DWithin, nearest neighbours with the KNN distance operator, point in polygon, distances and areas in metres, loading GeoJSON and shapefiles, invalid geometries, simplifying and subdividing shapes, and vector tiles with ST_AsMVT. Use when building store locators, delivery zones, maps or geofences, or when a spatial query is slow or returns distances in degrees.'
metadata:
  tags:
  - postgres
  - postgis
  - geospatial
  - gis
  - geography
  - spatial-index
  - nearest-neighbour
  - vector-tiles
---

# Geospatial data with PostGIS

PostGIS adds spatial types, functions and indexes to PostgreSQL, so "shops within 5 km" or "which zone contains
this address" is one indexed query next to the rest of the data. PostGIS 3.7 (released 30 October 2026) is current and
runs on PostgreSQL 14 to 19. Every example here ran on 3.7.0 with GEOS 3.15 and PostgreSQL 18.6, and on 3.6.3 before
that. PostGIS 3.7 needs GEOS 3.10 or later (3.15 for every feature), PROJ 6.1 or later and libgmp. It moves
`postgis_tiger_geocoder` and `address_standardizer` out to their own repositories and removes `ST_MemCollect`.

## Step 0: check the PostGIS version

Function availability and defaults change between PostGIS releases, so read what the server has.

```sql
SELECT name, default_version, installed_version FROM pg_available_extensions WHERE name LIKE 'postgis%';
CREATE EXTENSION IF NOT EXISTS postgis;       -- managed services: it is on their allowlist
SELECT postgis_full_version();                -- PostGIS, GEOS, PROJ and GDAL versions
SELECT postgis_extensions_upgrade();          -- after the server's PostGIS package was upgraded
```

Run the upgrade call in each database after new binaries or `pg_upgrade`. From the 2 series the announcement asks
for `ALTER EXTENSION postgis UPDATE;`, then `SELECT postgis_extensions_upgrade();` twice.

## geometry or geography

PostGIS has two spatial types. `geography` computes on the sphere in metres; `geometry` computes on a flat plane in
the units of its coordinate system. Pick by what you measure.

| Need | Type | Why |
|---|---|---|
| Points worldwide, distances and radius search in metres | `geography(Point, 4326)` | correct metres anywhere, no projection to choose |
| Shapes in one city or country, heavy geometry work (union, buffer, intersection) | `geometry(..., <local SRID>)` | full function set, fast planar math, metres in a local projection |
| Map display data, tiles | `geometry(..., 3857)` or 4326 | what web maps use; never measure distances in 3857 |

- SRID 4326 is longitude and latitude in degrees (WGS 84, what GPS and GeoJSON use). A `geometry` in 4326 measures
  in degrees: `ST_Distance` returns 0.045, not 5 km.
- SRID 3857 (Web Mercator) stretches distances away from the equator (by about 2 at latitude 60°).
- A local projection (a UTM zone, a national grid) gives accurate metres for a region.

## Tables and points from latitude and longitude

Store a point column with a type and SRID, and build points from longitude first, then latitude: `ST_MakePoint(x, y)`
takes x as longitude.

```sql
CREATE TABLE app.stores (
  id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name  text NOT NULL,
  geog  geography(Point, 4326) NOT NULL
);
CREATE INDEX stores_geog_gist ON app.stores USING gist (geog);

INSERT INTO app.stores (name, geog)
VALUES ('Alexanderplatz', ST_SetSRID(ST_MakePoint(13.4132, 52.5219), 4326)::geography);   -- lon, lat
```

Validate input before it reaches SQL: latitude between -90 and 90, longitude between -180 and 180. Swapped
coordinates put Berlin in the Indian Ocean without any error.

## Radius search: "everything within 5 km"

`ST_DWithin` is the radius test that uses the spatial index; `ST_Distance(...) < 5000` computes every distance and
does not. PostGIS 3.7 also speeds up `ST_DWithin` with GEOS prepared distance and caching.

```sql
SELECT id, name, ST_Distance(geog, $1::geography) AS metres
FROM app.stores
WHERE ST_DWithin(geog, $1::geography, 5000)                 -- metres for geography
ORDER BY metres
LIMIT 50;
-- $1 = 'SRID=4326;POINT(13.40 52.52)'
```

On a `geometry` column in a local projection the radius is in that projection's units (usually metres); on
`geometry` in 4326 it is degrees, which is why results look wrong.

## Nearest neighbours with the <-> operator

`ORDER BY geom <-> point LIMIT n` walks the GiST index from the nearest object outward, so "the 10 closest" costs
the same in a table of a thousand or a hundred million rows.

```sql
SELECT id, name, geog <-> $1::geography AS metres
FROM app.stores
ORDER BY geog <-> $1::geography
LIMIT 10;
```

Combine with a filter (`WHERE open_now`) carefully: a very selective filter makes the index walk many rows; a
partial index (`WHERE active`) or a radius cap with `ST_DWithin` keeps it bounded.

Use `<->` to order and `ST_Distance` to report: on `geography` the operator measures on a sphere, so one store came
back at 210.75 m from `<->` and 210.93 m from `ST_Distance` on 3.7.0.

## Point in polygon: zones, regions and geofences

Containment answers "which delivery zone is this address in". `ST_Intersects` uses the index and treats boundary
points as inside; `ST_Contains` excludes the boundary; `ST_Covers` includes it.

```sql
CREATE TABLE app.zones (
  id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  name  text NOT NULL,
  geom  geometry(MultiPolygon, 4326) NOT NULL
);
CREATE INDEX zones_geom_gist ON app.zones USING gist (geom);

SELECT id, name FROM app.zones
WHERE ST_Intersects(geom, ST_SetSRID(ST_MakePoint($1, $2), 4326));     -- $1 lon, $2 lat
```

Containment tests are correct in 4326 (no distance involved). For country-sized polygons with thousands of
vertices, split them once into small pieces with `ST_Subdivide` into a lookup table: each test then reads a small
polygon instead of a huge one.

```sql
CREATE TABLE app.zone_parts AS
SELECT id AS zone_id, ST_Subdivide(geom, 256) AS geom FROM app.zones;
CREATE INDEX zone_parts_geom_gist ON app.zone_parts USING gist (geom);
```

## Distances, lengths and areas in metres

Measure on `geography`, or on `geometry` transformed to a local projection; never on raw 4326 `geometry`.

```sql
SELECT ST_Distance(a.geog, b.geog) AS metres FROM app.stores a, app.stores b WHERE a.id = 1 AND b.id = 2;
SELECT ST_Area(geom::geography) / 1e6 AS km2 FROM app.zones WHERE id = $1;
SELECT ST_Length(ST_Transform(route, 25833)) AS metres FROM app.routes WHERE id = $1;   -- UTM 33N for Berlin
```

`ST_Transform` to a local SRID is also the way to `ST_Buffer` by metres on `geometry`.

## Loading GeoJSON, shapefiles and other formats

Small inputs arrive as GeoJSON from an API; files from a GIS (shapefile, GeoPackage, KML) load with GDAL's
`ogr2ogr`.

```sql
INSERT INTO app.zones (name, geom)
VALUES ($1, ST_Multi(ST_SetSRID(ST_GeomFromGeoJSON($2), 4326)));   -- $2 = the "geometry" member of a feature
SELECT jsonb_build_object('type', 'Feature', 'geometry', ST_AsGeoJSON(geom)::jsonb,
                          'properties', jsonb_build_object('id', id, 'name', name))
FROM app.zones WHERE id = $1;                                        -- back out as a GeoJSON feature
```

```bash
ogr2ogr -f PostgreSQL "PG:host=db.internal dbname=app user=app_loader" zones.gpkg \
  -nln app.zones_import -nlt PROMOTE_TO_MULTI -t_srs EPSG:4326 -lco GEOMETRY_NAME=geom
```

Load into a staging table, check it, then `INSERT ... SELECT` into the real one. `shp2pgsql` (shipped with PostGIS)
also turns a shapefile into SQL.

## Invalid geometries

Polygons from other systems are often invalid (self-intersections, rings in the wrong order), and invalid input
makes overlay functions fail with `TopologyException` or return wrong areas.

```sql
SELECT id, ST_IsValidReason(geom) FROM app.zones WHERE NOT ST_IsValid(geom);
UPDATE app.zones SET geom = ST_Multi(ST_CollectionExtract(ST_MakeValid(geom), 3)) WHERE NOT ST_IsValid(geom);
ALTER TABLE app.zones ADD CONSTRAINT zones_geom_valid CHECK (ST_IsValid(geom));
```

`ST_CollectionExtract(..., 3)` keeps only the polygon parts that `ST_MakeValid` may return beside lines or points.

## Simplifying shapes and serving vector tiles

Maps do not need every vertex. Simplify for display, and serve vector tiles straight from the database with
`ST_AsMVT`, which a map library (MapLibre, OpenLayers) draws.

```sql
SELECT ST_AsGeoJSON(ST_SimplifyPreserveTopology(geom, 0.0005)) FROM app.zones WHERE id = $1;   -- tolerance in degrees

-- one tile z/x/y in Web Mercator
WITH bounds AS (SELECT ST_TileEnvelope($1, $2, $3) AS env),
mvt AS (
  SELECT z.id, z.name, ST_AsMVTGeom(ST_Transform(z.geom, 3857), b.env) AS geom
  FROM app.zones z, bounds b
  WHERE z.geom && ST_Transform(b.env, 4326)
)
SELECT ST_AsMVT(mvt.*, 'zones') FROM mvt;
```

Serve tiles through a small tile server (pg_tileserv, Martin) or an API route with HTTP caching; tiles for static
data can be generated once.

## Spatial index choices

GiST is the default spatial index and serves `&&`, `ST_Intersects`, `ST_DWithin`, `ST_Contains` and `<->`.

- Index the column, not an expression around it: `WHERE ST_DWithin(geom::geography, ...)` on a `geometry` column
  cannot use the plain index; store `geography`, or index the expression `((geom::geography))`.
- `CREATE INDEX CONCURRENTLY` on live tables, and `ANALYZE` after bulk loads.
- SP-GiST is the alternative to GiST once a table passes a few thousand rows; compare both on your data. BRIN fits
  very large tables that are sorted spatially and rarely updated.

## Worked example: "show the 20 nearest open stores and whether each delivers to me"

A store locator combines a nearest-neighbour search on points with a point-in-polygon test per result.

1. Stores are `geography(Point, 4326)` with a GiST index, plus the columns this query reads:
   `ALTER TABLE app.stores ADD COLUMN zone_id bigint, ADD COLUMN open_now boolean NOT NULL DEFAULT true;`. Delivery
   zones are `geometry(MultiPolygon, 4326)` subdivided into `app.zone_parts`.
2. Build the user's point once from the browser's latitude and longitude, in the order longitude, latitude.
3. Query:

```sql
SELECT s.id, s.name, round((s.geog <-> me.g)::numeric) AS metres,
       EXISTS (SELECT 1 FROM app.zone_parts zp
               WHERE zp.zone_id = s.zone_id AND ST_Intersects(zp.geom, me.g::geometry)) AS delivers
FROM app.stores s,
     LATERAL (SELECT ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography AS g) me
WHERE s.open_now AND ST_DWithin(s.geog, me.g, 30000)
ORDER BY s.geog <-> me.g
LIMIT 20;
```

4. `EXPLAIN (ANALYZE)` shows an index scan on `stores_geog_gist` and index probes on `zone_parts_geom_gist`; the
   query answers in a few milliseconds.

## Verify a spatial schema and its queries

These checks ran on 3.7.0 against the tables above. The known-distance test catches a wrong type or swapped
coordinates before any user does.

```sql
SELECT f_table_name, f_geometry_column, type, srid FROM geometry_columns WHERE f_table_schema = 'app'
UNION ALL
SELECT f_table_name, f_geography_column, type, srid FROM geography_columns WHERE f_table_schema = 'app';
SELECT ST_Distance('SRID=4326;POINT(13.40 52.52)'::geography,
                   'SRID=4326;POINT(13.45 52.52)'::geography) AS metres;              -- 3393.97
SELECT count(*) AS outside FROM app.stores
WHERE NOT ST_Intersects(geog::geometry, ST_MakeEnvelope(5, 47, 16, 56, 4326));        -- 0 for a German chain
SELECT count(*) AS invalid FROM app.zones WHERE NOT ST_IsValid(geom);                 -- 0
```

Each declared column must show its real type and SRID. A table made with `CREATE TABLE ... AS` (like `zone_parts`)
reports `GEOMETRY` and SRID 0 here even though its values carry 4326, so declare the column when wrong SRIDs must be
refused. Then `EXPLAIN (ANALYZE)` the radius and nearest queries. For `ST_DWithin` the plan must use `stores_geog_gist`
with `Index Cond: (geog && _st_expand(...))`, in an `Index Scan` or a `Bitmap Index Scan` (a 501-row table planned the
bitmap). Nearest must show `Index Scan using stores_geog_gist` with `Order By: (geog <-> ...)`.

## Checklist

Check these points before you call spatial data done.

- [ ] Each spatial column has a declared type and SRID (`geography(Point, 4326)`, `geometry(MultiPolygon, 25833)`).
- [ ] Points are built longitude first; inputs are range-checked.
- [ ] Distances and areas are computed on `geography` or a local projection, never on 4326 `geometry`.
- [ ] Radius search uses `ST_DWithin`; nearest uses `<->` with `LIMIT`.
- [ ] GiST indexes exist on the columns queried; queries do not cast the indexed column.
- [ ] Imported shapes are valid (`ST_IsValid` check constraint), large polygons subdivided.

## Gotchas

These are the failures seen most often with PostGIS, each with its cause and fix.

1. **Distances like 0.045.** A `geometry` in SRID 4326 measures degrees. Use `geography`, or `ST_Transform` to a
   local projection.
2. **Points land in the ocean.** Latitude and longitude were swapped. `ST_MakePoint(longitude, latitude)`.
3. **The radius query is slow.** It filters with `ST_Distance(...) < r`, or casts the indexed column. Use
   `ST_DWithin` on the column as stored.
4. **`Operation on mixed SRID geometries`.** One side has SRID 0 or another SRID. `ST_SetSRID` on input, and
   declare the column's SRID so wrong inserts fail.
5. **`TopologyException` in `ST_Union` or `ST_Intersection`.** Invalid input geometry. `ST_MakeValid` first.
6. **Point in polygon is slow for big countries.** Every test reads a polygon with tens of thousands of vertices.
   `ST_Subdivide` into a lookup table.
7. **Functions missing after a PostGIS package upgrade.** The extension in the database is still the old version.
   Run `SELECT postgis_extensions_upgrade();` in each database.
8. **`function st_memcollect(geometry) does not exist` on 3.7.** The aggregate was removed. Use `ST_Collect`.
9. **`extension "postgis_tiger_geocoder" is not available` (or `address_standardizer`) on 3.7.** Both left the main
   package. Install them from their own repositories, or stay on 3.6 until you have.

## Anti-patterns in spatial queries

These habits work in a demo and fail on real data.

| Do not | Do instead |
|---|---|
| Store points as `geometry` in 4326 and measure with `ST_Distance` | Use `geography` for worldwide points, or transform to a local SRID |
| Filter with `ST_Distance(a, b) < r` | Filter with `ST_DWithin(a, b, r)`, which uses the index |
| Keep separate `lat` and `lon` columns and compute distance in the application | One `geography(Point, 4326)` column with a GiST index |
| Cast the indexed column in the query (`geom::geography`) | Store the type you query, or index that exact expression |
| Measure in SRID 3857 because the map uses it | Measure on `geography` or a local projection; keep 3857 for tiles |
| Load shapes straight into the live table | Load into staging, run `ST_IsValid`, then `INSERT ... SELECT` |

## See also

Related skills in this library, each one works on its own:

- `postgres-extensions-install`: getting PostGIS onto a server on each OS.
- `postgres-indexing`: GiST, BRIN, partial and expression indexes in general.
- `postgres-query-performance`: reading the plans of slow spatial queries.
- `postgres-bulk-load-etl`: staging tables and large imports.
- `postgres-zero-downtime-upgrades`: moving a server with PostGIS to a new major.
