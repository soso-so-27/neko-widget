import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {ageRatingPlan,checkPlan,errorDetails,runGroups,permissionFailure,approvedDescriptionUpdate,approvedDailyPhotoAppDescription,dailyPlusDescriptionChange,seasonalMovieAppMetadata,approvedStoreCopy1123,pickFields,storeCopy1123Previous,approvedReviewNotes1123v,approvedStoreCopy1124f,storeCopy1124fPrevious} from './asc-metadata-apply.mjs';

test('age rating dry-run compares the complete questionnaire, including new Apple fields',()=>{
  const desired=JSON.parse(readFileSync(new URL('./asc-metadata-1109d/age-rating.json',import.meta.url),'utf8'));
  const expected={dryRun:true,scope:'age-rating',changes:[],unavailableFields:[]};
  assert.deepEqual(ageRatingPlan({...desired,ageRatingOverride:null},desired),expected);
  const {datingAndRelationships,...current}=desired;
  assert.deepEqual(ageRatingPlan({...current,sharedLocation:true},desired),{
    ...expected,
    changes:[{field:'sharedLocation',from:true,to:false}],
    unavailableFields:['datingAndRelationships'],
  });
});

test('1111d permits only the daily-photo copy changes in the Japanese descriptions',()=>{
  // 1123: the home paragraph now ends with a later sentence; check the 1111d step on the text it had then.
  const desired=JSON.parse(readFileSync(new URL('./asc-metadata-1109d/version/1.0/ja.json',import.meta.url),'utf8')).description
    .replace('1年前のきょうや誕生日には、札の付いた1枚が届きます。','');
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
test('1123 store-copy-1123 permits only the exact previous to approved text',()=>{
  // 1124f: the repo moved on; check the 1123 step on the description and notes it had then.
  const desiredVersion={...JSON.parse(readFileSync(new URL('./asc-metadata-1109d/version/1.0/ja.json',import.meta.url),'utf8')),description:storeCopy1124fPrevious.description};
  const desiredReview={notes:storeCopy1124fPrevious.notes};
  const fields=['description','keywords','promotionalText'];
  const desired=pickFields(desiredVersion,fields),previous=pickFields(storeCopy1123Previous,fields);
  for(const field of fields)assert.notEqual(previous[field],desired[field]);
  // The approved copy itself.
  assert.ok(!desired.description.includes(String.fromCharCode(92)));
  assert.match(desired.description,/■ この子のこと（無料）\n誕生日・ワクチン・病院・体重を記録して/u);
  assert.match(desired.description,/■ ねこのまど Plus\n・まどを作って、家族や猫友を招く\n/u);
  assert.ok([...desired.promotionalText].length<=170);
  assert.ok([...desired.keywords].length<=100);
  assert.ok(desired.keywords.split(',').includes('迷子')&&desired.keywords.split(',').includes('猫友'));
  // 1123n: keywords merged with the words found in ASC (no ホーム画面), entered manually.
  assert.equal(desired.keywords,'ねこ,ネコ,ペット,愛猫,アルバム,写真整理,ウィジェット,家族,共有,お世話,記録,病院,メモ,黒猫,多頭飼い,見守り,迷子,防災,避難,健康管理,体重,通院,日記,猫友');
  assert.ok(!desired.keywords.split(',').includes('ホーム画面'));
  assert.ok(desiredReview.notes.includes('まどを作った直後の画面で、6 つの席と「招待する」から招待リンクを送れます。'));

  assert.equal(approvedStoreCopy1123(previous,desired),true);
  assert.equal(approvedStoreCopy1123(desired,desired),true);
  assert.equal(approvedStoreCopy1123({...previous,keywords:desired.keywords},desired),true);
  // 1123v: the notes in the repo moved on to 「招待する」, so store-copy-1123 now
  // refuses them; its own approved notes (「猫友を招く」) still pass.
  const notes={notes:desiredReview.notes.replace('「招待する」','「猫友を招く」')};
  assert.equal(approvedStoreCopy1123({notes:storeCopy1123Previous.notes},notes),true);
  assert.equal(approvedStoreCopy1123({notes:storeCopy1123Previous.notes},{notes:desiredReview.notes}),false);
  // Any other current value stops.
  for(const field of fields){
    assert.equal(approvedStoreCopy1123({...previous,[field]:previous[field]+'別の文'},desired),false);
    assert.equal(approvedStoreCopy1123({...previous,[field]:undefined},desired),false);
  }
  assert.equal(approvedStoreCopy1123({notes:storeCopy1123Previous.notes+'。'},notes),false);
  // Any desired text other than the approved one stops.
  assert.equal(approvedStoreCopy1123(previous,{...desired,description:desired.description.replace('980 円','990 円')}),false);
  assert.equal(approvedStoreCopy1123({notes:storeCopy1123Previous.notes},{notes:notes.notes+'追記'}),false);
  // Extra fields stop.
  assert.equal(approvedStoreCopy1123({...previous,supportUrl:desiredVersion.supportUrl},{...desired,supportUrl:desiredVersion.supportUrl}),false);
  assert.equal(approvedStoreCopy1123({...previous,whatsNew:'x'},desired),false);
  assert.equal(approvedStoreCopy1123({},{}),false);
  assert.equal(approvedStoreCopy1123(undefined,desired),false);
});
test('1123v review-notes-1123v permits only the review notes from the store-copy-1123 text to 「招待する」',()=>{
  // 1124f: the repo notes moved on; the 1123v approved notes are the 1124f previous.
  const desiredNotes=storeCopy1124fPrevious.notes;
  const sentence='まどを作った直後の画面で、6 つの席と「招待する」から招待リンクを送れます。';
  assert.ok(desiredNotes.includes(sentence));
  assert.ok(!desiredNotes.includes('猫友を招く'));
  const previousNotes=desiredNotes.replace('「招待する」','「猫友を招く」');
  const desired={notes:desiredNotes};
  assert.equal(approvedReviewNotes1123v({notes:previousNotes},desired),true);
  assert.equal(approvedReviewNotes1123v(desired,desired),true);
  // Any other current notes stop, including the older store-copy-1123 previous.
  assert.equal(approvedReviewNotes1123v({notes:storeCopy1123Previous.notes},desired),false);
  assert.equal(approvedReviewNotes1123v({notes:previousNotes+'。'},desired),false);
  assert.equal(approvedReviewNotes1123v({notes:undefined},desired),false);
  assert.equal(approvedReviewNotes1123v({},desired),false);
  // Any other desired notes stop.
  assert.equal(approvedReviewNotes1123v({notes:previousNotes},{notes:desiredNotes+'追記'}),false);
  assert.equal(approvedReviewNotes1123v({notes:previousNotes},{notes:previousNotes}),false);
  assert.equal(approvedReviewNotes1123v({notes:previousNotes},{notes:desiredNotes.replace('「招待する」','「招く」')}),false);
  // Only the notes field.
  assert.equal(approvedReviewNotes1123v({notes:previousNotes,demoAccountRequired:false},{...desired,demoAccountRequired:false}),false);
  assert.equal(approvedReviewNotes1123v({notes:previousNotes,demoAccountRequired:false},desired),false);
  assert.equal(approvedReviewNotes1123v({notes:previousNotes},{description:desiredNotes}),false);
  assert.equal(approvedReviewNotes1123v(undefined,desired),false);
  assert.equal(approvedReviewNotes1123v({notes:previousNotes},undefined),false);
});
test('1124f store-copy-1124f moves only description and notes from the approved text to the 11/24 text',()=>{
  const version=JSON.parse(readFileSync(new URL('./asc-metadata-1109d/version/1.0/ja.json',import.meta.url),'utf8'));
  const review=JSON.parse(readFileSync(new URL('./asc-metadata-1109d/review-information.json',import.meta.url),'utf8'));
  const description={description:version.description},notes={notes:review.notes};
  const previousDescription={description:storeCopy1124fPrevious.description},previousNotes={notes:storeCopy1124fPrevious.notes};
  // The previous text is exactly what store-copy-1123 and review-notes-1123v approved.
  assert.equal(approvedStoreCopy1123({description:storeCopy1123Previous.description},previousDescription),true);
  assert.equal(approvedReviewNotes1123v({notes:previousNotes.notes.replace('「招待する」','「猫友を招く」')},previousNotes),true);
  // The approved copy itself.
  assert.ok(!version.description.includes(String.fromCharCode(92))&&!review.notes.includes(String.fromCharCode(92)));
  assert.ok(version.description.includes('作品を開くのは Plus です（初めての方は 14 日間無料）。'));
  assert.ok(version.description.includes('Plus は、初めての方は 14 日間無料で試せます。'));
  assert.ok(!/(?<!初めての方は )14 日間無料/u.test(version.description));
  assert.ok(version.description.includes('Plus の間に届いた作品も開けます。止まるのは、作ったまどへの写真・家族の手帳の共有・自動保存など、新しく増えるものです。'));
  assert.ok([...version.description].length<=4000);
  for(const sentence of ['購入画面は「この子」タブ右上の歯車（設定）→「Plusについて」です。',
    '「まど」タブの「まどを作る」から Plus で作り',
    '2 台目で「参加する」を押したあと、1 台目でねこのまどを開くと参加が完了します。',
    '1 つのまどにつき 1 人 1 日 5 枚まで',
    '家族の手帳の猫の代表写真は、その猫のページの「…」から「この写真を通報」できます。',
    '「この子」タブで「この子を追加」（名前だけで足せます）のあと「病院」から開けます。'])assert.ok(review.notes.includes(sentence),sentence);
  assert.ok(!review.notes.includes('みんなのまど'));
  assert.ok(!review.notes.includes('「設定」→「Plusについて」'));
  assert.ok([...review.notes].length<=4000);

  for(const [previous,desired] of [[previousDescription,description],[previousNotes,notes]]){
    assert.notDeepEqual(previous,desired);
    assert.equal(approvedStoreCopy1124f(previous,desired),true);
    assert.equal(approvedStoreCopy1124f(desired,desired),true);
    const field=Object.keys(desired)[0];
    // Any other current value stops, including the older approved texts.
    assert.equal(approvedStoreCopy1124f({[field]:previous[field]+'。'},desired),false);
    assert.equal(approvedStoreCopy1124f({[field]:undefined},desired),false);
    assert.equal(approvedStoreCopy1124f({},desired),false);
    // Any desired text other than the approved one stops.
    assert.equal(approvedStoreCopy1124f(previous,{[field]:desired[field]+'追記'}),false);
    assert.equal(approvedStoreCopy1124f(previous,previous),false);
  }
  assert.equal(approvedStoreCopy1124f({description:storeCopy1123Previous.description},description),false);
  assert.equal(approvedStoreCopy1124f({notes:storeCopy1123Previous.notes},notes),false);
  assert.equal(approvedStoreCopy1124f(previousDescription,{description:version.description.replace('980 円','990 円')}),false);
  // One field per group, and only description or notes.
  assert.equal(approvedStoreCopy1124f({...previousDescription,...previousNotes},{...description,...notes}),false);
  assert.equal(approvedStoreCopy1124f({...previousDescription,keywords:version.keywords},description),false);
  assert.equal(approvedStoreCopy1124f({keywords:version.keywords},{keywords:version.keywords}),false);
  assert.equal(approvedStoreCopy1124f({promotionalText:version.promotionalText},{promotionalText:version.promotionalText}),false);
  assert.equal(approvedStoreCopy1124f({notes:previousNotes.notes,demoAccountRequired:false},notes),false);
  assert.equal(approvedStoreCopy1124f(previousNotes,{description:review.notes}),false);
  assert.equal(approvedStoreCopy1124f(undefined,description),false);
  assert.equal(approvedStoreCopy1124f(previousDescription,undefined),false);
  // The workflow offers the scope.
  const workflow=readFileSync(new URL('../../.github/workflows/asc-metadata-1109d.yml',import.meta.url),'utf8');
  assert.match(workflow,/review-notes-1123v, store-copy-1124f, age-rating\]/u);
});
