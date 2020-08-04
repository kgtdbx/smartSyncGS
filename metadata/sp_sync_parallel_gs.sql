create or replace procedure METADATA.SP_SYNC_PARALLEL_GS(I_METHOD VARCHAR,I_CLUSTER_COUNT float, I_SRC_DB VARCHAR, I_TGT_DB VARCHAR, I_SCHEMA VARCHAR)
    returns ARRAY
    language JAVASCRIPT
    execute as caller
as
$$
//note:  this proc returns an array, either success or fail right now

const method= I_METHOD;
const cluster_count=I_CLUSTER_COUNT;
const src_db  = I_SRC_DB;
const tgt_db  = I_TGT_DB;
const src_schema  = I_SCHEMA;
const tgt_schema  = I_SCHEMA;

const internal = "INTERNAL_";
const tgt_meta_schema = tgt_schema + "_METADATA";
const meta_schema = internal + tgt_schema + "_METADATA";
const tgt_schema_streams = internal + tgt_schema + "_STREAMS";
const tgt_schema_notifications = internal + tgt_schema + "_NOTIFICATIONS";
const tgt_schema_tmp = internal + tgt_schema + "_TMP";
const table_execution_plan = "TABLE_EXECUTION_PLAN";

const smart_copy_compact="SMART_COPY_COMPACT";
const smart_copy_init="SMART_COPY_INIT";
const object_log = "OBJECT_LOG";
const scheduler = "SCHEDULER";
const scheduler_history= "SCHEDULER_HISTORY";
const scheduler_stream="SCHEDULER_STREAM";
const notifications_tmp = "NOTIFICATIONS_TMP";
const information_schema_tables_tmp = "INFO_SCHEMA_TABLES_TMP";
const max_loop = 32;
const min_jobs_per_cluster = 150;
//const crux_delivery_version_initialize='INITIALIZE'

const method_scheduler='SCHEDULER';
const method_listener='LISTENER';
const method_worker='WORKER';

const status_begin = "BEGIN";
const status_end = "END";
const status_warning = "WARNING";
const status_failure = "FAILURE";
const version_default = "000000";
const version_initial = "000001";

var return_array = [];
var counter = 0;
var loop_counter = 0;
var notifications="";
var prev_schema="PREV";
var status= status_end;
var scheduler_session_id=0;
var partition_id=0;


var procName = Object.keys(this)[0]+"-"+method;

function log ( msg ) {
   var d=new Date();
   var UTCTimeString=("00"+d.getUTCHours()).slice(-2)+":"+("00"+d.getUTCMinutes()).slice(-2)+":"+("00"+d.getUTCSeconds()).slice(-2);
   return_array.push(UTCTimeString+" "+msg);
}

function flush_log (status){
   var message="";
   var sqlquery="";
   for (i=0; i < return_array.length; i++) {
      message=message+String.fromCharCode(13)+return_array[i];
   }
   message=message.replace(/'/g,"");

   for (i=0; i<2; i++) {
      try {

         var sqlquery = "INSERT INTO \"" + tgt_db + "\"." + meta_schema + ".log (target_schema, version, scheduler_session_id, partition_id, method, status,message) values ";
         sqlquery = sqlquery + "('" + tgt_schema + "','" + version_default + version_default + "',"+scheduler_session_id +","+partition_id+ ",'" + method + "','" + status + "','" + message + "');";
         snowflake.execute({sqlText: sqlquery});
         break;
      }
      catch (err) {
         sqlquery=`
            CREATE TABLE IF NOT EXISTS "`+ tgt_db + `".` + meta_schema + `.log (
               id integer AUTOINCREMENT (0,1)
               ,create_ts timestamp_ltz default current_timestamp
               ,target_schema varchar
               ,version varchar
               ,scheduler_session_id number default 0
               ,session_id number default to_number(current_session())
               ,partition_id integer
               ,method varchar
               ,status varchar
               ,message varchar)`;
         snowflake.execute({sqlText: sqlquery});
      }
   }
}

function get_local_inventory(){
   const max_number_schemas="365";
   var sqlquery="";
   var schema_name="";
   var counter=0;

   log("GET TABLE METADATA ");

   sqlquery=`
      CREATE OR REPLACE
      TABLE "` + tgt_db + `"."` + tgt_schema_tmp + `"."` + information_schema_tables_tmp  + `" (
         table_schema varchar
         ,table_name varchar
         ,base_table_name varchar
         ,row_count bigint
         ,bytes bigint
         ,last_altered_utc timestamp_tz(9)
      )`;
   snowflake.execute({sqlText:  sqlquery});

   try {
      sqlquery=`
         INSERT /* # ` + counter + ` */
         INTO "` + tgt_db + `"."` + tgt_schema_tmp + `"."` + information_schema_tables_tmp  + `"
            SELECT table_schema,table_name,substr(table_name,0,len(table_name)-7)::varchar base_table_name
                   ,row_count, bytes,convert_timezone('UTC',last_altered) last_altered_utc
            FROM "`+tgt_db+`".information_schema.tables
            WHERE table_schema rlike '` + tgt_schema + `_([0-9]{4}-[0-9]{2}-[0-9]{2})?(INITIAL)?'
            `;
      snowflake.execute({sqlText:  sqlquery});

   }
   catch(err) {
       sqlquery=`
          SELECT schema_name
          FROM "`+tgt_db+`".information_schema.schemata
          WHERE schema_name rlike '` + tgt_schema + `_([0-9]{4}-[0-9]{2}-[0-9]{2})?(INITIAL)?'
          `;

       var ResultSet = (snowflake.createStatement({sqlText:sqlquery})).execute();

       while (ResultSet.next() && counter < max_number_schemas ) {
          counter+=1;
          schema_name=ResultSet.getColumnValue(1);
          log("   GET VIEW METADATA FOR: "+schema_name)

          sqlquery=`
             INSERT /* # ` + counter + ` */
             INTO "` + tgt_db + `"."` + tgt_schema_tmp + `"."` + information_schema_tables_tmp  + `"
                SELECT table_schema,table_name,substr(table_name,0,len(table_name)-7)::varchar base_table_name
                       ,row_count, bytes,convert_timezone('UTC',last_altered) last_altered_utc
                FROM "`+tgt_db+`".information_schema.tables
                WHERE table_schema ='`+schema_name+`'
                `;
          snowflake.execute({sqlText:  sqlquery});
       }
   }
}

function process_requests(partition_id) {
   var counter=0;
   var prev_schema="";
   var table_name="";
   var delivery_id="";
   var curr_schema_name="";
   var curr_table_version="";
   var next_schema_name="";
   var next_table_version="";
   var sqlquery="";

   log("GET EXECUTION PLAN")

   sqlquery=`
      SELECT view_name, crux_delivery_version delivery_id
             ,curr_schema_name, curr_table_version
             ,next_schema_name, next_table_version
      FROM   "` + tgt_db + `"."` + tgt_schema_tmp + `"."` + notifications_tmp + `"
      WHERE (crux_delivery_version='`+smart_copy_init+`'
             OR curr_table_version::int >= 1)
        AND partition_id = `+partition_id+`
      ORDER BY notification_dt, crux_delivery_version, view_name
      `;

   var ResultSet = (snowflake.createStatement({sqlText:sqlquery})).execute();

   while (ResultSet.next()) {
      counter+=1;
      table_name=ResultSet.getColumnValue(1);
      delivery_id=ResultSet.getColumnValue(2);
      curr_schema_name=ResultSet.getColumnValue(3);
      curr_table_version=ResultSet.getColumnValue(4);
      next_schema_name=ResultSet.getColumnValue(5);
      next_table_version=ResultSet.getColumnValue(6);

      if (next_schema_name != prev_schema) {
         log("   USE SCHEMA: "+next_schema_name);
         prev_schema=next_schema_name;
         sqlquery=`
               CREATE SCHEMA IF NOT EXISTS "` + tgt_db + `"."` + next_schema_name + `"`;
         snowflake.execute({sqlText:  sqlquery});
      }

      log("  PROCESS NOTIFICATION FOR "+table_name);

      if (delivery_id == smart_copy_init) {
          log("  INITIAL VERSION "+next_table_version);
          sqlquery=`
              CREATE /* # ` + counter + ` */ OR REPLACE
              TABLE "` + tgt_db + `"."` + next_schema_name + `"."` + table_name + '_' + next_table_version + `" AS
                         SELECT * FROM "` + src_db + `"."` + src_schema + `"."` + table_name + `"
                         `;
          snowflake.execute({sqlText:  sqlquery});
      } else {
          try {
             sqlquery=`
                   DELETE /* # ` + counter + ` */
                   FROM "` + tgt_db + `"."` + next_schema_name + `"."` + table_name + '_' + next_table_version + `"
                   WHERE "crux_delivery_id" = '`+delivery_id+`'`;
             snowflake.execute({sqlText:  sqlquery});

             log("  NEW VERSION "+next_table_version);
             sqlquery=`
                   INSERT /* # ` + counter + ` */
                   INTO "` + tgt_db + `"."` + next_schema_name + `"."` + table_name + '_' + next_table_version + `"
                      SELECT * FROM "` + src_db + `"."` + src_schema + `"."` + table_name + `"
                      WHERE "crux_delivery_id" = '`+delivery_id+`'`;
             snowflake.execute({sqlText:  sqlquery});
          }
          catch (err) {
             if (curr_table_version == version_default) {
                log("  INITIAL VERSION "+next_table_version);
             } else {
                log("  CLONED VERSION "+next_table_version);
                sqlquery=`
                   CREATE /* # ` + counter + ` */
                   TABLE "` + tgt_db + `"."` + next_schema_name + `"."` + table_name + '_' + next_table_version + `"
                      CLONE "` + tgt_db + `"."` + curr_schema_name + `"."` + table_name + '_' + curr_table_version + `"
                      `;
                snowflake.execute({sqlText:  sqlquery});
                sqlquery=`
                   DELETE /* # ` + counter + ` */
                   FROM "` + tgt_db + `"."` + next_schema_name + `"."` + table_name + '_' + next_table_version + `"
                   WHERE "crux_delivery_id" = '`+delivery_id+`'`;
                snowflake.execute({sqlText:  sqlquery});
                sqlquery=`
                   INSERT /* # ` + counter + ` */
                   INTO "` + tgt_db + `"."` + next_schema_name + `"."` + table_name + '_' + next_table_version + `"
                      SELECT * FROM "` + src_db + `"."` + src_schema + `"."` + table_name + `"
                      WHERE "crux_delivery_id" = '`+delivery_id+`'`;
                snowflake.execute({sqlText:  sqlquery});
             }
          }
      }
   }
}

function record_work() {
   var objects_processed=0;

   log("RECORD WORK")

   get_local_inventory();

   try {
       sqlquery=`
          INSERT INTO "` + tgt_db + `"."` + meta_schema + `"."` + object_log + `"
             SELECT n.org, n.notification_dt, n.notification_type, n.view_name
                    ,n.crux_resource_id, n.crux_delivery_version, n.crux_ingestion_dt, n.frame_group
                    ,n.curr_schema_name prev_schema_name, n.curr_table_version prev_table_version
                    ,n.next_schema_name curr_schema_name, n.next_table_version curr_table_version
                    ,t.row_count ,t.bytes, convert_timezone('UTC',current_timestamp()) create_ts
             FROM   "` + tgt_db + `"."` + tgt_schema_tmp + `"."` + notifications_tmp + `" n
             INNER JOIN "` + tgt_db + `"."` + tgt_schema_tmp + `"."` + information_schema_tables_tmp  + `" t
                     ON n.view_name=t.base_table_name and n.next_schema_name=t.table_schema
             WHERE crux_delivery_version='`+smart_copy_init+`'
                   OR curr_table_version::int > 0
             ORDER BY notification_dt, view_name, crux_delivery_version`;

       snowflake.execute({sqlText:  sqlquery});
   }
   catch (err) {
       sqlquery=`
          CREATE TABLE "` + tgt_db + `"."` + meta_schema + `"."` + object_log + `" AS
             SELECT n.org, n.notification_dt, n.notification_type, n.view_name
                    ,n.crux_resource_id, n.crux_delivery_version, n.crux_ingestion_dt, n.frame_group
                    ,n.curr_schema_name prev_schema_name, n.curr_table_version prev_table_version
                    ,n.next_schema_name curr_schema_name, n.next_table_version curr_table_version
                    ,t.row_count, t.bytes, convert_timezone('UTC',current_timestamp()) create_ts
             FROM   "` + tgt_db + `"."` + tgt_schema_tmp + `"."` + notifications_tmp + `" n
             INNER JOIN "` + tgt_db + `"."` + tgt_schema_tmp + `"."` + information_schema_tables_tmp  + `" t
                     ON n.view_name=t.base_table_name and n.next_schema_name=t.table_schema
             WHERE crux_delivery_version='`+smart_copy_init+`'
                   OR curr_table_version::int > 0
             ORDER BY notification_dt, view_name, crux_delivery_version`;

       snowflake.execute({sqlText:  sqlquery});
   } 
   sqlquery=`
      SELECT COUNT(*)
      FROM   "` + tgt_db + `"."` + tgt_schema_tmp + `"."` + notifications_tmp + `" 
   `;
    
   var ResultSet = (snowflake.createStatement({sqlText:sqlquery})).execute();

   if (ResultSet.next()) {
      objects_processed=ResultSet.getColumnValue(1); 
      log("OBJECTS PROCESSED: "+objects_processed);
   } else {
      throw new Error('NOTIFICATIONS TMP TABLE NOT FOUND!');
   }

}

function get_share_inventory(){
   var sqlquery="";

   log("GET TABLE METADATA FOR: "+src_db+"."+src_schema);

   snowflake.execute({sqlText: "SHOW VIEWS IN SCHEMA \"" + src_db + "\".\"" + src_schema + "\";"});

   sqlquery=`
      CREATE OR REPLACE TABLE "` + tgt_db + `"."` + tgt_schema_tmp + `".` + notifications_tmp + ` AS
         WITH notification AS (
            SELECT seq4() id, null::varchar org, current_date()::varchar notification_dt
                   ,'`+smart_copy_init+`'::varchar notification_type, table_name view_name
                   ,null::varchar crux_resource_id
                   ,'`+smart_copy_init+`'::varchar crux_delivery_version
                   ,null::varchar crux_ingestion_dt, null::varchar frame_group
                   ,null::varchar curr_schema_name, '`+version_default+`'::varchar curr_table_version
                   ,'`+tgt_schema+`'||'_INITIAL'::varchar next_schema_name
                   ,lpad((curr_table_version::int+1),6,'0')::varchar next_table_version
                   ,0::int seq
            FROM (SELECT "database_name" database_name,"schema_name" schema_name,"name" table_name
                  FROM (SELECT * FROM TABLE(RESULT_SCAN(LAST_QUERY_ID())) LIMIT 100)
                  WHERE table_name NOT IN (
                     SELECT base_table_name
                     FROM "` + tgt_db + `"."` + tgt_schema_tmp + `"."` + information_schema_tables_tmp  + `")
                  )
            ORDER BY table_name)
         SELECT trunc(((id-1)/((SELECT COUNT(*)+1 FROM notification)/
            (least(ceil((select count(*) from notification)/`+min_jobs_per_cluster+`),`+cluster_count+`)))))+1 partition_id
            , n.*
         FROM notification n
      `;

   snowflake.execute({sqlText: sqlquery});

}

function get_requests(){

   sqlquery=`
      CREATE OR REPLACE TABLE "` + tgt_db + `"."` + tgt_schema_tmp + `"."` + notifications_tmp + `" AS
         WITH notificataion AS (
            SELECT seq4() id, *
            FROM (SELECT n.*
                        ,curr_schema_name
                        ,curr_table_version
                        ,'`+tgt_schema+`'||'_'||substr(notification_dt,0,10)::varchar next_schema_name
                        ,lpad((curr_table_version::int+1),6,'0')::varchar next_table_version
                        ,row_number() over (partition by n.view_name order by n.notification_dt,n.crux_delivery_version) seq
                  FROM   "` + tgt_db + `"."` + tgt_schema_notifications + `"."` + notifications + `" n
                  LEFT OUTER JOIN (
                     SELECT view_name,curr_table_version, curr_schema_name
                     FROM (
                        SELECT view_name, curr_table_version, curr_schema_name
                                 ,row_number() over (partition by view_name
                                                   order by curr_table_version desc) rownum
                        FROM "` + tgt_db + `"."` + meta_schema + `"."` + object_log  + `"
                        WHERE nvl(notification_type,'NULL') != '`+smart_copy_compact+`')
                     WHERE rownum=1) i ON n.view_name=i.view_name
                  WHERE notification_dt > (SELECT min(d)
                                          FROM (
                                             SELECT min(to_varchar(create_ts,'YYYY-MM-DD')) d
                                             FROM   "` + tgt_db + `"."` + meta_schema + `"."` + object_log +`" 
                                             UNION SELECT current_date d ))
                  AND nvl(crux_resource_id,'NULL')||'_'||nvl(crux_delivery_version,'NULL') NOT IN (
                     SELECT nvl(crux_resource_id,'NULL')||'_'||nvl(crux_delivery_version,'NULL')
                     FROM   "` + tgt_db + `"."` + meta_schema + `"."` + object_log +`")) 
            WHERE seq=1
            ORDER BY notification_dt, view_name, crux_delivery_version)
         SELECT trunc(((id-1)/((SELECT COUNT(*)+1 FROM notification)/
            (least(ceil((select count(*) from notification)/`+min_jobs_per_cluster+`),`+cluster_count+`)))))+1 partition_id
            , n.*
         FROM notification n
      `;

   snowflake.execute({sqlText:  sqlquery});
}

function wait_for_completion() {

   sqlquery=`
         CREATE OR REPLACE TABLE "` + tgt_db + `"."` + meta_schema + `"."` + scheduler + `" 
            (create_ts timestamp_ltz default current_timestamp
            , scheduler_session_id bigint
            , partition_id integer)
   `;
   snowflake.execute({sqlText:  sqlquery});

   sqlquery=`
         CREATE OR REPLACE STREAM "` + tgt_db + `"."` + meta_schema + `"."` + scheduler_stream+ `" 
         ON TABLE "` + tgt_db + `"."` + meta_schema + `"."` + scheduler + `"
   `;
           
   snowflake.execute({sqlText:  sqlquery});

    // create one row per configured number of clusters with 1 minute in between
    sqlquery=`
        SELECT distinct partition_id
        FROM   "` + tgt_db + `"."` + tgt_schema_tmp + `"."` + notifications_tmp + `" 
        ORDER BY 1
    `;

    var ResultSet = (snowflake.createStatement({sqlText:sqlquery})).execute();

    while (ResultSet.next()) {
      var partition_id_tmp=ResultSet.getColumnValue(1); 

      log("SCHEDULING WORKER "+partition_id_tmp)

      sqlquery=`
            INSERT INTO "` + tgt_db + `"."` + meta_schema + `"."` + scheduler + `" 
               (scheduler_session_id,partition_id)
            VALUES (current_session(),'`+partition_id_tmp+`')
      `;
      snowflake.execute({sqlText:  sqlquery});

      sqlquery=`
         SELECT session_id
         FROM  "` + tgt_db + `"."` + meta_schema + `".log l
         WHERE l.partition_id=`+partition_id_tmp+` 
           AND l.scheduler_session_id = current_session()
           AND l.status = '`+status_begin+`'
           AND l.method = '`+method_worker+`'
         `;

      loop_counter=0
      while (loop_counter<60) {
         var ResultSet2 = (snowflake.createStatement({sqlText:sqlquery})).execute();
         if (ResultSet2.next()) {
               break;
         } else {
            loop_counter+=1;
            log("WAITING FOR WORKER "+partition_id_tmp+" TO START");
            snowflake.execute({sqlText: "call system$wait(45)" });
         }
      }
    }
    
   loop_counter=0
   while (loop_counter<60) {
      sqlquery=`
         SELECT s.partition_id, nvl(l.session_id,0) worker_session_id
         FROM  "` + tgt_db + `"."` + meta_schema + `"."` + scheduler + `"  s
         LEFT OUTER JOIN "` + tgt_db + `"."` + meta_schema + `".log l
               ON l.scheduler_session_id = s.scheduler_session_id 
                  AND l.partition_id=s.partition_id
                  AND l.status in ('`+status_end+`','`+status_failure+`')
                  AND l.method = '`+method_worker+`'
         WHERE s.scheduler_session_id=current_session()
            AND WORKER_SESSION_ID = 0
      `;

      counter=0
      var ResultSet = (snowflake.createStatement({sqlText:sqlquery})).execute();
      while (ResultSet.next()) {
         counter+=1;
         var partition_id_tmp=ResultSet.getColumnValue(1);
         worker_session_id=ResultSet.getColumnValue(2)

         log("WAITING FOR WORKER "+partition_id_tmp+" TO COMPLETE");
      }
      if (counter<=0)  {
         break;
      } else {
         loop_counter+=1;
         snowflake.execute({sqlText: "call system$wait(60)" });
      }                   
   } 
}

try {
    snowflake.execute({sqlText: "CREATE SCHEMA IF NOT EXISTS \"" + tgt_db + "\"." + meta_schema + ";"});
                                                                        
    // snowflake.execute({sqlText: "CREATE DATABASE IF NOT EXISTS \"" + tgt_db + "\";"});
    snowflake.execute({sqlText: "CREATE SCHEMA IF NOT EXISTS \"" + tgt_db + "\"." + tgt_meta_schema + ";"});
    snowflake.execute({sqlText: "CREATE SCHEMA IF NOT EXISTS \"" + tgt_db + "\".\"" + tgt_schema_streams + "\";"});
     // get start time for copy process from the snowflake server

    var resultSet = (snowflake.createStatement({sqlText:"SELECT date_part(epoch_seconds,convert_timezone('UTC',current_timestamp))"})).execute();
    if (resultSet.next()) {
        process_start_time_epoch=resultSet.getColumnValue(1);
    }

   if (method==method_scheduler) {
      log("procName: " + procName + " " + status_begin);
      flush_log(status_begin);

      snowflake.execute({sqlText: "CREATE OR REPLACE TRANSIENT SCHEMA \"" + tgt_db + "\".\"" + tgt_schema_tmp + "\";"});

      sqlquery=`
        SELECT table_name
        FROM  "` + tgt_db + `".information_schema.tables
        WHERE table_schema = '`+tgt_schema_notifications+`' and TABLE_NAME LIKE '%--CRUX_NOTIFICATIONS--%'
        `;

      var ResultSet = (snowflake.createStatement({sqlText:sqlquery})).execute();
      if (ResultSet.next()) {
        notifications = ResultSet.getColumnValue(1)
        log("USING NOTIFICATIONS TABLE: "+notifications);
      } else {
        throw new Error('NOTIFICATIONS TABLE NOT FOUND!');
      }

      get_local_inventory();
      get_share_inventory();
      wait_for_completion();
      record_work();

      throw new Error('WAIT 2');

      loop_counter=0;
      do {
         loop_counter+=1;
         get_requests();
         wait_for_completion();
         counter=record_work();
      } while (counter>0 && loop_counter < max_loop);

      log("procName: " + procName + " " + status_end);
      flush_log(status);
      return return_array;

   } else if (method==method_listener) {

      log("procName: " + procName + " " + status_begin);
      flush_log(status_begin);

      sqlquery=`
         SELECT scheduler_session_id, partition_id
         FROM "` + tgt_db + `"."` + meta_schema + `"."` + scheduler_stream+ `" 
         WHERE metadata$action='INSERT' AND metadata$isupdate='FALSE'
         ORDER BY scheduler_session_id, partition_id
      `;

      var ResultSet = (snowflake.createStatement({sqlText:sqlquery})).execute();

      while(ResultSet.next()){
         scheduler_session_id = ResultSet.getColumnValue(1);
         var partition_id_tmp = ResultSet.getColumnValue(2);

         log("REQUEST WORKER FOR SCHEDULER ID "+scheduler_session_id+" PARTITION "+partition_id_tmp);
      }
 
      log("procName: " + procName + " " + status_end);
      flush_log(status_end);
      return return_array;

   } else if (method==method_worker){

      sqlquery=`
         INSERT INTO "` + tgt_db + `"."` + meta_schema + `".log 
                  (target_schema, version,   scheduler_session_id,  partition_id, method     ,status,message)
            SELECT target_schema, version, s.scheduler_session_id,s.partition_id,'`+method+`',status,message
            FROM "` + tgt_db + `"."` + meta_schema + `"."` + scheduler_stream+ `" s
               INNER JOIN "` + tgt_db + `"."` + meta_schema + `".log l ON l.session_id=s.scheduler_session_id
            WHERE metadata$action='INSERT' AND metadata$isupdate='FALSE'
              AND method='`+method_scheduler+`'
              AND status='`+status_begin+`'
            ORDER BY s.scheduler_session_id, s.partition_id
      `;
      snowflake.execute({sqlText: sqlquery });

      sqlquery=`
         SELECT scheduler_session_id, partition_id
         FROM  "` + tgt_db + `"."` + meta_schema + `".log
         WHERE session_id=current_session()
           AND method='`+method_worker+`'
         ORDER BY scheduler_session_id, partition_id
      `;
      var ResultSet = (snowflake.createStatement({sqlText:sqlquery})).execute();

      while(ResultSet.next()){
         return_array = []
         log("procName: " + procName + " " + status_begin);

         scheduler_session_id = ResultSet.getColumnValue(1);
         partition_id = ResultSet.getColumnValue(2);

         log("PROCESSING REQUESTS FOR SCHEDULER ID "+scheduler_session_id+" PARTITION "+partition_id);

         process_requests(partition_id);

         log("procName: " + procName + " " + status_end);
         flush_log(status_end);
      }
      
      return return_array;
   }

}
catch (err) {
    log("ERROR found - MAIN try command");
    log("err.code: " + err.code);
    log("err.state: " + err.state);
    log("err.message: " + err.message);
    log("err.stacktracetxt: " + err.stacktracetxt);
    log("procName: " + procName );
    flush_log(status_failure);
    return return_array;
}
$$;