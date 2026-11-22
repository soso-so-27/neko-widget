import test from 'node:test';
import assert from 'node:assert/strict';
import {checkPlan,errorDetails,runGroups,permissionFailure,approvedDescriptionUpdate,approvedDailyPhotoAppDescription,dailyPlusDescriptionChange,seasonalMovieAppMetadata} from './asc-metadata-apply.mjs';

test('1111d permits only the daily-photo copy changes in the Japanese descriptions',()=>{
  const desired=JSON.parse(readFileSync(new URL('./asc-metadata-1109d/version/1.0/ja.json',import.meta.url),'utf8')).description;
  const before=desired.replace('毎日ちがう 1 枚に入れ替わります。','')
    .replace('■ ねこのまど Plus\n','■ ねこのまど Plus\n・毎日、新しい 1 枚がホーム画面に\n');
  assert.notEqual(before,desired);
  assert.equal(approvedDailyPhotoAppDescription(before,desired),true);
  assert.equal(approvedDailyPhotoAppDescription(before+'\n別の追記',desired),false);
  assert.equal(approvedDailyPhotoAppDescription(before,desired.replace('980 円','990 円')),false);
  assert.equal(dailyPlusDescriptionChange('うちの子との毎日を続ける。まど・毎日の新しい 1 枚・まとめ'),
    '月の作品、まど、家族の手帳、メモ、保存');
  assert.equal(dailyPlusDescriptionChange('月の作品、まど、家族の手帳、メモ、保存'),null);
  assert.throws(()=>dailyPlusDescriptionChange('別の説明'),/STOP_SCOPE/u);
});
import {readFileSync} from 'node:fs';
test('1121f removes exactly two movie mentions and the movie keyword',()=>{
  const desired=JSON.parse(readFileSync(new URL('./asc-metadata-1109d/version/1.0/ja.json',import.meta.url),'utf8'));
  const before=desired.description
    .replace('12 月には 1 年の作品も届きます。','12 月には 1 年の作品も届きます。季節のムービーもあります。')
    .replace('・月の作品、1年の作品','・月の作品、季節のムービー');
  assert.notEqual(before,desired.description);
  assert.ok(desired.keywords.split(',').includes('迷子'));
  assert.doesNotMatch(desired.keywords,/ムービー/u);
  assert.match(desired.description,/病院で見せる：気付いたことと写真・動画・体重/u);

  const current={description:before,keywords:'ねこ, ウィジェット,ムービー,家族,共有'};
  const approved={description:desired.description,keywords:'ねこ, ウィジェット,迷子,家族,共有'};
  assert.deepEqual(seasonalMovieAppMetadata(current,desired),approved);
  assert.deepEqual(seasonalMovieAppMetadata(approved,desired),approved);
  assert.deepEqual(seasonalMovieAppMetadata({...current,keywords:'ねこ,迷子,ウィジェット,ムービー,家族'},desired),
    {description:desired.description,keywords:'ねこ,迷子,ウィジェット,家族'});
  for(const unexpected of [
    {...current,description:before.replace('980 円','990 円')},
    {...current,description:before.replace('季節のムービーもあります。','')},
    {...current,keywords:'ねこ,ウィジェット,家族'},
    {...current,keywords:'猫,ムービー,ムービー'},
  ])assert.throws(()=>seasonalMovieAppMetadata(unexpected,desired),/STOP_SCOPE/u);
});
test('1113d removes only the paid photo-memo bullet',()=>{
  const desired=JSON.parse(readFileSync(new URL('./asc-metadata-1109d/version/1.0/ja.json',import.meta.url),'utf8')).description;
  const before=desired.replace('■ ねこのまど Plus\n','■ ねこのまど Plus\n・写真に新しいメモを書く\n');
  assert.notEqual(before,desired);
  assert.equal(approvedDescriptionUpdate(before,desired),true);
  assert.equal(approvedDescriptionUpdate(before,desired.replace('980 円','990 円')),false);
  assert.equal(approvedDescriptionUpdate(before+'\n別の追記',desired),false);
  assert.equal(approvedDescriptionUpdate(before.replace('・写真に新しいメモを書く\n','・写真に新しいメモを書く\n・写真に新しいメモを書く\n'),desired),false);
});
const allowed=[{scope:'app-info',locale:'ja',field:'subtitle',value:'approved'}];
const change={scope:'app-info',locale:'ja',field:'subtitle',to:'approved'};

test('1110b description allows only the two approved edits and preserves all other copy',()=>{
  const before='approved opening\n季節のムービーもあります。\napproved middle（3GB・記録 3,000 件まで）\napproved ending';
  const after=before.replace('季節のムービーもあります。','季節のムービーもあります。作品を開くのは Plus です（14 日間無料）。')
    .replace('（3GB・記録 3,000 件まで）','（3GB・記録 3,000 件まで。お試し中は 250MB）');
  assert.equal(approvedDescriptionUpdate(before,after),true);
  assert.equal(approvedDescriptionUpdate(after,after),true);
  assert.equal(approvedDescriptionUpdate(before,after.replace('approved ending','other ending')),false);
  assert.equal(approvedDescriptionUpdate(undefined,after),false);
  assert.equal(approvedDescriptionUpdate(before+before,after),false);
});
test('only the exact approved field, locale and value can be applied',()=>{
  assert.equal(checkPlan({dryRun:true,adds:[],updates:[change],deletes:[]},allowed).length,1);
  for(const c of [{...change,locale:'en-US'},{...change,field:'name'},{...change,to:'different'}])assert.throws(()=>checkPlan({dryRun:true,adds:[c],updates:[],deletes:[]},allowed));
  assert.throws(()=>checkPlan({dryRun:true,adds:[],updates:[],deletes:[change]},allowed));
  assert.throws(()=>checkPlan({dryRun:false,adds:[],updates:[]},allowed));
});

test('write credential stays in the protected metadata workflow only',()=>{
  const workflow=readFileSync(new URL('../../.github/workflows/asc-metadata-1109d.yml',import.meta.url),'utf8');
  assert.match(workflow,/environment: asc-metadata/);
  assert.doesNotMatch(workflow,/environment: testflight|OWNER_INTERNAL_GROUP_ID/);
  assert.match(workflow,/asc-metadata-apply\.mjs --validate/);
  const readonly=readFileSync(new URL('../../.github/workflows/asc-readonly.yml',import.meta.url),'utf8');
  assert.match(readonly,/environment: testflight/);
  assert.doesNotMatch(readonly,/asc-metadata/);
  const implementation=readFileSync(new URL('./asc-metadata-apply.mjs',import.meta.url),'utf8');
  assert.doesNotMatch(implementation,/\['(?:submit|review)'/);
});

test('ordinary API failure continues while protected boundaries stop all groups',()=>{
  const visited=[];
  const actions=[['first',()=>{visited.push('first');throw Error('STOP_API');}],['second',()=>visited.push('second')]];
  assert.deepEqual(runGroups(actions,()=>{}),['first']);
  assert.deepEqual(visited,['first','second']);
  for(const code of ['STOP_PERMISSION','STOP_SCOPE','STOP_AGE_RATING','STOP_READBACK','STOP_IDENTITY']){
    let later=false;
    assert.throws(()=>runGroups([['first',()=>{throw Error(code)}],['second',()=>{later=true}]],()=>{}),new RegExp(code));
    assert.equal(later,false);
  }
});

test('Apple error details survive but keys, IDs and contacts do not',()=>{
  const details=errorDetails(JSON.stringify({actions:[{error:JSON.stringify({errors:[{code:'ENTITY_ERROR.ATTRIBUTE.INVALID',title:'Invalid attribute',detail:'whatsNew not allowed: secret-key 1234567890 owner@example.com'}]})}]}),'',['secret-key']);
  assert.equal(details[0].code,'ENTITY_ERROR.ATTRIBUTE.INVALID');
  assert.match(details[0].detail,/whatsNew not allowed/);
  for(const value of ['secret-key','1234567890','owner@example.com'])assert.ok(!JSON.stringify(details).includes(value));
  assert.doesNotMatch(JSON.stringify(errorDetails('', '-----BEGIN PRIVATE KEY----- hidden',[])),/hidden/);
});

test('first version never requests whatsNew',()=>{
  const input=JSON.parse(readFileSync(new URL('./asc-metadata-1109d/version/1.0/ja.json',import.meta.url),'utf8'));
  assert.equal(Object.hasOwn(input,'whatsNew'),false);
  assert.deepEqual(Object.keys(input).sort(),['description','keywords','promotionalText','supportUrl']);
});
test('Apple permission error suffixes still stop every group without an HTTP code',()=>{
  for(const text of ['FORBIDDEN_ERROR','NOT_AUTHORIZED','AUTHENTICATION_ERROR','HTTP 403','UNAUTHORIZED_ERROR'])assert.equal(permissionFailure(text),true);
  assert.equal(permissionFailure('ENTITY_ERROR.ATTRIBUTE.INVALID whatsNew'),false);
});

test("1115c permits exactly approved #1007 description changes",()=>{
 const before="ねこのまどは、iPhone の写真から猫の写真を見つけて、アルバムとホーム画面のウィジェットに出すアプリです。\n\n■ 探さなくても、猫の写真がそろう\n写真へのアクセスを許可すると、iPhone の中の猫の写真を見つけて並べます。猫かどうかの見分けは iPhone の中で行います。元の写真を動かしたり、消したりはしません。\n\n■ ホーム画面で、ふと目が合う\nウィジェットを置くと、猫の写真がホーム画面に出ます。新しい 1 枚は、くもったまどで届きます。札をタップすると晴れて、その日の 1 枚に会えます。毎日ちがう 1 枚に入れ替わります。\n\n■ 毎月 1 日に、先月の作品が届く\nその月の猫の写真から、本のように開ける「月の作品」をつくります。12 月には 1 年の作品も届きます。季節のムービーもあります。作品を開くのは Plus です（14 日間無料）。\n\n■ みんなのまどで、家族や猫友に届ける\n名前を付けたまどを作って、家族や猫友を招待します（1 つのまどに 6 人まで）。写真に短いひとことを添えて届けると、相手のホーム画面のウィジェットにも出せます。ハートで「見たよ」を返せます。\n・招待した人だけのまどです。公開のタイムライン、検索、フォローはありません。\n・写真とひとことは、まどの人だけが開ける鍵で暗号化して届けます。運営者は中身を読めません。\n・届ける前と表示する前に、iPhone の中で不適切な内容でないかを確かめます。困ったときは、通報やブロックができます。\n\n■ のわのまど\nねこのまどの黒猫「のわ」の写真が、毎日 1 枚届きます。だれでも無料で受け取れます。\n\n■ 家族の手帳\n猫のごはん、薬、病院、預けるときのことを、家族で一緒に書けます。だれが書いても、家族みんなの iPhone に同じ記録がそろいます。中身は家族だけが開ける鍵で暗号化して届けます。\n\n■ 暮らしのツール（無料）\n猫の写真と「この子のこと」から、暮らしで使うものをつくれます。\n・写真を見せる：自慢の 9 枚を、人に見せたりスライドショーにしたり\n・病院で見せる：気付いたことと写真・動画・体重を、先生に見せる 1 画面に\n・預けるとき：お世話のお願いと毎日のチェック表を、PDF や文で渡せる\n・迷子のとき：チラシと SNS 用の画像、連絡したところの記録\n・避難に備える：持ち出すものと期限、見直しの時期のお知らせ、「いま避難する」画面\n\n■ ねこのまど Plus\n・月の作品、季節のムービー\n・まどを作って、家族と写真を届け合う\n・家族の手帳を作る\n・猫のこと・メモ・ツールの記録を保存して、新しい iPhone に戻せる（3GB・記録 3,000 件まで。お試し中は 250MB）\n\n招待されてまどや家族の手帳に入る人は、無料です。\n\nPlus は 14 日間無料で試せます。お試しが終わると、月額 980 円（税込）で自動で更新されます。更新の 24 時間前までに解約すれば、料金はかかりません。解約は iPhone の「設定」→ Apple アカウント →「サブスクリプション」からできます。やめても、写真・まど・メモ・手帳の記録は消えません。Apple のファミリー共有には対応していません。\n\nプライバシーポリシー：https://nekonomado.com/privacy/ \n利用規約：https://www.apple.com/legal/internet-services/itunes/dev/stdeula/\n\niOS 17.1 以降の iPhone で使えます。";
 const desired="ねこのまどは、iPhone の写真から猫の写真を見つけて、アルバムとホーム画面のウィジェットに出すアプリです。\n\n■ 探さなくても、猫の写真がそろう\n写真へのアクセスを許可すると、iPhone の中の猫の写真を見つけて並べます。猫かどうかの見分けは iPhone の中で行います。元の写真を動かしたり、消したりはしません。\n\n■ ホーム画面で、ふと目が合う\nウィジェットを置くと、猫の写真がホーム画面に出ます。新しい 1 枚は、くもったまどで届きます。札をタップすると晴れて、その日の 1 枚に会えます。毎日ちがう 1 枚に入れ替わります。\n\n■ 毎月 1 日に、先月の作品が届く\nその月の猫の写真から、本のように開ける「月の作品」をつくります。12 月には 1 年の作品も届きます。季節のムービーもあります。作品を開くのは Plus です（14 日間無料）。\n\n■ みんなのまどで、家族や猫友に届ける\n名前を付けたまどを作って、家族や猫友を招待します（1 つのまどに 6 人まで）。写真に短いひとことを添えて届けると、相手のホーム画面のウィジェットにも出せます。ハートで「見たよ」を返せます。\n・招待した人だけのまどです。公開のタイムライン、検索、フォローはありません。\n・写真とひとことは、まどの人だけが開ける鍵で暗号化して届けます。運営者は中身を読めません。通報された写真だけは、確認用の画像を運営者が確かめます。\n・iPhone の「センシティブな内容の警告」がオンのときは、届ける前と表示する前に、iPhone の中で確かめます。困ったときは、通報やブロックができます。\n\n■ のわのまど\nねこのまどの黒猫「のわ」の写真が、毎日 1 枚届きます。だれでも無料で受け取れます。\n\n■ 家族の手帳\n猫のごはん、薬、病院、預けるときのことを、家族で一緒に書けます。だれが書いても、家族みんなの iPhone に同じ記録がそろいます。中身は家族だけが開ける鍵で暗号化して届けます。\n\n■ 暮らしのツール（無料）\n猫の写真と「この子のこと」から、暮らしで使うものをつくれます。\n・写真を見せる：自慢の 9 枚を、人に見せたりスライドショーにしたり\n・病院で見せる：気付いたことと写真・動画・体重を、先生に見せる 1 画面に\n・預けるとき：お世話のお願いと毎日のチェック表を、PDF や文で渡せる\n・迷子のとき：チラシと SNS 用の画像、連絡したところの記録\n・避難に備える：持ち出すものと期限、見直しの時期のお知らせ、「いま避難する」画面\n\n■ ねこのまど Plus\n・月の作品、季節のムービー\n・まどを作って、家族と写真を届け合う\n・家族の手帳を作る\n・猫のこと・メモ・ツールの記録を保存して、新しい iPhone に戻せる（3GB・記録 3,000 件まで。お試し中は 250MB）\n\n招待されてまどや家族の手帳に入る人は、無料です。\n\nPlus は 14 日間無料で試せます。お試しが終わると、月額 980 円（税込）で自動で更新されます。更新の 24 時間前までに解約すれば、料金はかかりません。解約は iPhone の「設定」→ Apple アカウント →「サブスクリプション」からできます。やめても、この iPhone の写真・メモ・まどの写真・手帳の記録は消えません。自動保存のコピーは、やめてから 12 か月後に消えます。Apple のファミリー共有には対応していません。\n\nプライバシーポリシー：https://nekonomado.com/privacy/ \n利用規約：https://www.apple.com/legal/internet-services/itunes/dev/stdeula/\n\niOS 17.1 以降の iPhone で使えます。";
 assert.equal(approvedDescriptionUpdate(before,desired),true);
 assert.equal(approvedDescriptionUpdate(before,desired.replace("980 円","990 円")),false);
 assert.equal(approvedDescriptionUpdate(before+"別の文",desired),false);
});
