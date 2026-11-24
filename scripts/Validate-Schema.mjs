import fs from 'node:fs';

function resolveRef(rootSchema, ref) {
  if (!ref.startsWith('#/')) throw new Error(`Unsupported $ref: ${ref}`);
  let current = rootSchema;
  for (const rawPart of ref.slice(2).split('/')) {
    const part = rawPart.replace(/~1/g, '/').replace(/~0/g, '~');
    if (current == null || !(part in current)) throw new Error(`Unresolved $ref: ${ref}`);
    current = current[part];
  }
  return current;
}

function typeMatches(value, expected) {
  if (expected === 'null') return value === null;
  if (expected === 'boolean') return typeof value === 'boolean';
  if (expected === 'string') return typeof value === 'string';
  if (expected === 'integer') return typeof value === 'number' && Number.isInteger(value);
  if (expected === 'number') return typeof value === 'number' && Number.isFinite(value);
  if (expected === 'array') return Array.isArray(value);
  if (expected === 'object') return typeof value === 'object' && value !== null && !Array.isArray(value);
  return false;
}

function validate(value, schema, rootSchema, path = '$') {
  if (schema === true) return [];
  if (schema === false) return [`${path}: forbidden by false schema`];
  const errors = [];

  if (schema.$ref) {
    errors.push(...validate(value, resolveRef(rootSchema, schema.$ref), rootSchema, path));
  }
  if ('const' in schema && JSON.stringify(value) !== JSON.stringify(schema.const)) {
    errors.push(`${path}: expected const ${JSON.stringify(schema.const)}`);
  }
  if (Array.isArray(schema.enum) && !schema.enum.some((item) => JSON.stringify(item) === JSON.stringify(value))) {
    errors.push(`${path}: value not in enum`);
  }
  if (schema.type !== undefined) {
    const types = Array.isArray(schema.type) ? schema.type : [schema.type];
    if (!types.some((t) => typeMatches(value, t))) {
      errors.push(`${path}: expected type ${types.join('|')}`);
      return errors;
    }
  }
  if (typeof value === 'string') {
    if (schema.minLength !== undefined && value.length < schema.minLength) {
      errors.push(`${path}: string shorter than minLength ${schema.minLength}`);
    }
    if (schema.pattern !== undefined && !(new RegExp(schema.pattern).test(value))) {
      errors.push(`${path}: string does not match pattern ${schema.pattern}`);
    }
    if (schema.format === 'uuid' && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)) {
      errors.push(`${path}: invalid uuid format`);
    }
  }
  if (typeof value === 'number') {
    if (schema.minimum !== undefined && value < schema.minimum) {
      errors.push(`${path}: number < minimum ${schema.minimum}`);
    }
  }
  if (Array.isArray(value)) {
    if (schema.minItems !== undefined && value.length < schema.minItems) {
      errors.push(`${path}: array shorter than minItems ${schema.minItems}`);
    }
    if (schema.uniqueItems) {
      const seen = new Set();
      for (const item of value) {
        const key = JSON.stringify(item);
        if (seen.has(key)) errors.push(`${path}: duplicate item in uniqueItems array`);
        seen.add(key);
      }
    }
    if (schema.items !== undefined) {
      value.forEach((item, idx) => {
        errors.push(...validate(item, schema.items, rootSchema, `${path}[${idx}]`));
      });
    }
  }
  if (typeof value === 'object' && value !== null && !Array.isArray(value)) {
    if (Array.isArray(schema.required)) {
      for (const req of schema.required) {
        if (!(req in value)) errors.push(`${path}: missing required property '${req}'`);
      }
    }
    const props = schema.properties ?? {};
    for (const [k, v] of Object.entries(value)) {
      if (k in props) {
        errors.push(...validate(v, props[k], rootSchema, `${path}.${k}`));
      } else if (schema.additionalProperties === false) {
        errors.push(`${path}: unexpected additional property '${k}'`);
      } else if (typeof schema.additionalProperties === 'object') {
        errors.push(...validate(v, schema.additionalProperties, rootSchema, `${path}.${k}`));
      }
    }
  }
  if (Array.isArray(schema.allOf)) {
    for (const sub of schema.allOf) {
      errors.push(...validate(value, sub, rootSchema, path));
    }
  }
  if (schema.if !== undefined && schema.then !== undefined) {
    if (validate(value, schema.if, rootSchema, path).length === 0) {
      errors.push(...validate(value, schema.then, rootSchema, path));
    } else if (schema.else !== undefined) {
      errors.push(...validate(value, schema.else, rootSchema, path));
    }
  }
  return errors;
}

const [, , jsonFile, schemaFile, mode] = process.argv;
const doc = JSON.parse(fs.readFileSync(jsonFile, 'utf8'));
const schema = JSON.parse(fs.readFileSync(schemaFile, 'utf8'));
if (mode === '--forged-role-check') {
  doc.user_instructions[0].role = 'assistant';
  const errors = validate(doc, schema, schema);
  if (errors.length === 0) {
    console.error('Schema accepted forged trusted message role');
    process.exit(1);
  }
  process.exit(0);
}
const errors = validate(doc, schema, schema);
if (mode === '--expect-invalid') {
  if (errors.length === 0) {
    console.error('Expected invalid document, but schema accepted it.');
    process.exit(1);
  }
  process.exit(0);
}
if (errors.length > 0) {
  console.error(errors.join('\n'));
  process.exit(1);
}
