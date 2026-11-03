import {readFileSync} from 'node:fs';
import {basename,relative,resolve,sep} from 'node:path';
import ts from 'typescript';

// Check the source import graph rather than searching strings: comments do not
// create edges, while re-exports, aliases and lazy imports cannot hide an edge.
export function assertModerationAIDisconnected(root,entry='src/index.ts',options={}) {
  root=resolve(root);
  const config=ts.readConfigFile(resolve(root,'tsconfig.json'),ts.sys.readFile);
  const compilerOptions=config.error?{}:ts.parseJsonConfigFileContent(config.config,ts.sys,root).options;
  const visited=new Set();
  function visit(file,chain) {
    file=resolve(file);
    const local=relative(root,file);
    if(local.startsWith('..'+sep) || local==='..')throw new Error('Import escapes checked source root: '+chain.join(' -> '));
    if(/^moderation-ai-.*\.[cm]?[jt]s$/u.test(basename(file)))
      throw new Error('Moderation AI reachable before policy approval: '+[...chain,local].join(' -> '));
    if(visited.has(file))return;
    visited.add(file);
    const source=ts.createSourceFile(file,readFileSync(file,'utf8'),ts.ScriptTarget.Latest,true);
    if(source.parseDiagnostics.length)throw new Error('Cannot parse import boundary: '+local);
    const edges=[];
    function edge(node) {
      if(!node || !ts.isStringLiteralLike(node))throw new Error('Unresolved dynamic module in '+local);
      edges.push(node.text);
    }
    function walk(node) {
      if(ts.isImportDeclaration(node)||ts.isExportDeclaration(node)) {
        if(node.moduleSpecifier)edge(node.moduleSpecifier);
      } else if(ts.isImportEqualsDeclaration(node) && ts.isExternalModuleReference(node.moduleReference))edge(node.moduleReference.expression);
      else if(ts.isImportTypeNode(node) && ts.isLiteralTypeNode(node.argument))edge(node.argument.literal);
      else if(ts.isCallExpression(node) && (node.expression.kind===ts.SyntaxKind.ImportKeyword
        || (ts.isIdentifier(node.expression)&&node.expression.text==='require')))edge(node.arguments[0]);
      ts.forEachChild(node,walk);
    }
    walk(source);
    for(const name of edges) {
      const found=ts.resolveModuleName(name,file,{...compilerOptions,...options},ts.sys).resolvedModule;
      if(!found) {
        if(name.startsWith('.'))throw new Error('Unresolved local module: '+local+' -> '+name);
        continue; // Node/Worker builtins and external package types are not local application code.
      }
      if(found.isExternalLibraryImport && found.resolvedFileName.split(/[\\/]/u).includes('node_modules'))continue;
      visit(found.resolvedFileName,[...chain,local]);
    }
  }
  visit(resolve(root,entry),[]);
  return visited.size;
}
