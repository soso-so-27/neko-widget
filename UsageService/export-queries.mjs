export function queries(from,to){
 const filter=`day BETWEEN '${from}' AND '${to}' AND app != '0.0 (1)'`;
 return {
 days:{columns:['day','app','devices'],sql:`SELECT day,app,devices FROM usage_days WHERE ${filter} ORDER BY day,app`},
 events:{columns:['day','app','name','total','devices','device_fraction'],sql:`SELECT e.day,e.app,e.name,e.total,e.devices,CAST(e.devices AS REAL)/d.devices AS device_fraction FROM usage_events e JOIN usage_days d USING(day,app) WHERE e.day BETWEEN '${from}' AND '${to}' AND e.app != '0.0 (1)' ORDER BY e.day,e.app,e.name`},
 states:{columns:['day','app','name','value','devices'],sql:`SELECT day,app,name,value,devices FROM usage_states WHERE ${filter} ORDER BY day,app,name,value`},
 plus:{columns:['day','app','context','shown','purchased','count_ratio'],sql:`WITH entries AS (SELECT day,app,substr(name,18) AS context FROM usage_events WHERE name LIKE 'plus_offer_shown.%' UNION SELECT day,app,substr(name,16) AS context FROM usage_events WHERE name LIKE 'plus_purchased.%') SELECT e.day,e.app,e.context,COALESCE(s.total,0) AS shown,COALESCE(p.total,0) AS purchased,CAST(COALESCE(p.total,0) AS REAL)/NULLIF(s.total,0) AS count_ratio FROM entries e LEFT JOIN usage_events s ON s.day=e.day AND s.app=e.app AND s.name='plus_offer_shown.'||e.context LEFT JOIN usage_events p ON p.day=e.day AND p.app=e.app AND p.name='plus_purchased.'||e.context WHERE e.day BETWEEN '${from}' AND '${to}' AND e.app != '0.0 (1)' ORDER BY e.day,e.app,e.context`}
 };
}
