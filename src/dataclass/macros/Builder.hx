package dataclass.macros;

#if macro
import haxe.macro.Context;
import haxe.macro.Expr;
import haxe.macro.Type;

using haxe.macro.ExprTools;
using Lambda;
using StringTools;

private typedef FieldDataProperties = {
	optional: Bool, 
	defaultValue: Expr, 
	validator: Expr
}

class Builder
{
	static public function build() : Array<Field> {
		var fields = Context.getBuildFields();
		var cls = Context.getLocalClass().get();
		
		if (cls.meta.has("immutable")) 
			Context.error("@immutable is deprecated, use '-lib immutable' and 'implements Immutable' instead.", cls.pos);
		
		// Fields aren't available on Context.getLocalClass().
		// need to supply them here. They're available on the superclass though.
		var dataClassFields = includedFields(fields, cls);
		var fieldMap = new Map<Field, FieldDataProperties>();
		
		// Test if class implements HaxeContracts, then throw ContractException instead.
		var haxeContracts = cls.interfaces.map(function(i) return i.t.get()).exists(function(ct) {
			return ct.name == "HaxeContracts";
		});

		function throwError(errorString : ExprOf<String>) : Expr {
			return haxeContracts
				? macro throw new haxecontracts.ContractException($errorString, this)
				: macro throw $errorString;
		}		

		for (f in dataClassFields) {
			// If @col metadata, check the format
			for (col in f.meta.filter(function(m) return m.name == "col")) {
				try {
					var param = col.params[0];
					if (!param.expr.match(EConst(CInt(_)))) {
						Context.error("@col can only take a single int as parameter.", param.pos);
					}
				} catch (e : Dynamic) {
					Context.error("@col must take a single int as parameter.", col.pos);
				}
			}
			
			//trace('===' + f.name);
			//trace(f.kind);
			
			var optional = switch f.kind {
				case FVar(TPath(p), _) | FProp(_, _, TPath(p), _): 
					// StdTypes.Null is created when Context.toComplexType is used.
					p.name == "Null" || (p.name == "StdTypes" && p.sub == "Null");
				
				case _: 
					false;
			}
			
			var fieldType : ComplexType = switch f.kind {
				case FVar(t, _): t;
				case FProp(_, _, t, _): t;
				case _: null;
			}
			
			// If a default value exists, extract it from the field
			var defaultValue : Expr = switch f.kind {
				case FVar(t, e) if (e != null): e;
				case FProp(get, set, t, e) if (e != null): e;
				case _: macro null;
			}
			
			// Make the field optional if it has a default value
			if (defaultValue.toString() != 'null' && !optional) {				
				switch defaultValue.expr {
					// Special case for js optional values: Date.now() will be transformed to this:
					case ECall( { expr: EConst(CIdent("__new__")), pos: _ }, [ { expr: EConst(CIdent("Date")), pos: _ }]):
						// Make it into its real value:
						defaultValue.expr = (macro Date.now()).expr;
					case _:
				}
				
				//Context.warning(f.name + ' type: ' + f.kind + ' default: ' + defaultValue.toString(), f.pos);
				optional = true;
			}

			// If field has no type, try to extract it from the default value, if it exists
			if (optional && fieldType == null) {
				try {
					var typed = Context.typeExpr(defaultValue);
					var type = Context.toComplexType(typed.t);
					
					switch f.kind {
						case FVar(_, e): f.kind = FVar(type, e);
						case FProp(get, set, _, e): f.kind = FProp(get, set, type, e);
						case _:
					}
				} catch (e : Dynamic) {
					// Let the compiler handle the error.
				}
			}
			
			var validatorMeta = f.meta.find(function(m) return m.name == "validate");
			var validator = validatorMeta == null ? null : validatorMeta.params[0];
			
			if (validatorMeta != null) {
				f.meta.remove(validatorMeta);
			}
			
			fieldMap.set(f, {
				optional: optional, 
				defaultValue: defaultValue, 
				validator: validator
			});

			if(optional) f.meta.push({
				pos: cls.pos,
				params: [],
				name: ':optional'
			});
		}
		
		///// Data is collected, now transform the fields /////
		
		var assignments = [];
		var validationFields = [];
		var dataValidationExpressions = [];
		var anonymousValidationFields : Array<Field> = [];
		var allOptional = ![for (f in fieldMap) f].exists(function(f) return f.optional == false);
		
		for (f in dataClassFields) {
			var data = fieldMap.get(f);
			var defaultValue = data.defaultValue;
			var optional = data.optional;
			var validator = data.validator;
			var name = f.name;
			var clsName = cls.name;
			
			var fieldType = switch f.kind {
				case FVar(t, _), FProp(_, _, t, _): t;
				case FFun(f): f.ret;
			}
			
			var assignment = optional
				? macro data.$name != null ? data.$name : $defaultValue
				: macro data.$name;
				
			// Create a new Expr to set the correct pos
			assignment = { expr: assignment.expr, pos: f.pos };
			
			// If the type can be converted using the DynamicObjectConverter, mark it with metadata
			switch f.kind {
				case FVar(TPath(p), _) | FProp(_, _, TPath(p), _):
					var typeName = switch p {
						case { name: "Null", pack: _, params: [TPType(TPath( { name: n, pack: _, params: _ } ))] } :
							n;
						case _:
							p.name;
					};
					
					if (Converter.DynamicObjectConverter.supportedTypes.has(typeName)) {
						// convertFrom is for incoming fields
						f.meta.push({
							pos: f.pos,
							params: [{expr: EConst(CString(typeName)), pos: f.pos}],
							name: "convertFrom"
						});

						// convertTo excludes non-public fields in conversions
						if(f.access.has(APublic)) f.meta.push({
							pos: f.pos,
							params: [{expr: EConst(CString(typeName)), pos: f.pos}],
							name: "convertTo"
						});
					}
				case _:
			}

			function setterAssignmentExpressions(param : String, existingSetter : Null<Expr>) : Array<Expr> {
				function fieldAssignmentTests(param : String) : Array<Expr> {				
					var assignments = [];

					if (!optional && Validator.nullTestAllowed(fieldType)) {
						var throwStatement = throwError(macro "Field " + $v{clsName} + "." + $v{name} + " was null.");
						assignments.push(macro if ($i{param} == null) $throwStatement);
					}
					
					if (validator != null) {
						var errorString = macro "Field " + $v{clsName} + "." + $v{name} + ' failed validation "' + $validator + '" with value "' + this.$name + '"';
						assignments.push(Validator.createValidator(fieldType, macro $i{param}, optional, validator, throwError(errorString), false));
					}
					
					return assignments;
				}
				
				if (existingSetter == null) existingSetter = {expr: EBlock([]), pos: f.pos};
				switch existingSetter.expr {
					case EBlock(exprs):
						var assignments = fieldAssignmentTests(param);						
						if (exprs.length == 0) assignments.push(macro return this.$name = $i{param});
						
						return assignments.concat(exprs);
						
					case _: 
						return setterAssignmentExpressions(param, {expr: EBlock([existingSetter]), pos: existingSetter.pos});
				}				
			}
			
			function createValidationSetter(getter : String, type : ComplexType) {
				f.kind = FProp(getter, "set", type, null);
				validationFields.push({
					pos: f.pos,
					name: "set_" + name,
					meta: null,
					kind: FFun({
						ret: type,
						params: null,
						args: [{
							value: null,
							type: type,
							opt: false,
							name: name
						}],
						expr: {expr: EBlock(setterAssignmentExpressions(name, null)), pos: f.pos}
					}),
					doc: null,
					access: [APrivate]
				});
			}

			function createAnonymousValidationField(type : ComplexType) {
				anonymousValidationFields.push({
					pos: f.pos,
					name: f.name,
					meta: if(optional) [{
						pos: f.pos,
						params: null,
						name: ":optional"
					}] else null,
					kind: FVar(type, null),
					doc: null,
					access: []
				});
				
				// Assumptions for these expressions: data is Dynamic<Dynamic>, failed an Array<String>
				// will be used to create a static "validate" field on each DataClass implemented type.
				dataValidationExpressions.push(Validator.createValidator(
					fieldType, macro $p{['data', name]}, optional, validator, 
					macro failed.push($v{name}), !optional // Test field existence only for non-optional fields
				));
			}

			switch f.kind {
				case FVar(type, e):
					createValidationSetter("default", type);
					createAnonymousValidationField(type);

				// If a property setter already exists, inject validation into the beginning of it.
				case FProp(get, set, type, e) if (set == "set"):
					var accessorField = fields.find(function(f2) return f2.name == "set_" + f.name);
					switch accessorField.kind {
						case FFun(f2):
							f2.expr.expr = EBlock(setterAssignmentExpressions(f2.args[0].name, f2.expr));
						case _:
							Context.error("Invalid setter accessor", accessorField.pos);
					}
					createAnonymousValidationField(type);
					
				case FProp(_, set, type, _):
					createAnonymousValidationField(type);
					
				case FFun(_):
			}
			
			// Add to assignment in constructor
			assignments.push(macro this.$name = $assignment);
			
			if(validator != null) {
				// Set the validator expr to a const so it will pass compilation
				validator.expr = EConst(CString(validator.toString()));
			}
		}

		cls.meta.add("dataClassFields", [for(f in dataClassFields) if(f.access.has(APublic)) macro $v{f.name}], cls.pos);

		
		if (!cls.isInterface) {
			var constructor = fields.find(function(f) return f.name == "new");

			if (constructor == null) {
				// If all fields are optional, create a default argument assignment
				if (allOptional) assignments.unshift(macro if (data == null) data = {});
				
				fields.push({
					pos: cls.pos,
					name: 'new',
					meta: [],
					kind: FFun({
						ret: null,
						params: [],
						expr: {expr: EBlock(assignments), pos: cls.pos},
						args: [{
							value: null,
							type: TAnonymous(anonymousValidationFields),
							opt: allOptional,
							name: 'data'
						}]
					}),
					doc: null,
					access: [APublic]
				});
			} else {
				switch constructor.kind {
					case FFun(f):
						// Set function argument "data" to the validation field
						if (f.args.length > 0 && f.args[0].name == "data" && f.args[0].type == null) {
							f.args[0].type = TAnonymous(anonymousValidationFields);
						}
						
						switch f.expr.expr {
							case EBlock(exprs): f.expr.expr = EBlock(assignments.concat(exprs));
							case _: f.expr.expr = EBlock(assignments.concat([f.expr]));
						}
					case _:
						Context.error("Invalid constructor.", constructor.pos);
				}
			}
		}
		
		// Create a static validation method
		
		dataValidationExpressions.unshift(macro var failed = []);
		// All the validation expressions are now located here
		dataValidationExpressions.push(macro return failed);
		
		//trace(dataValidationExpressions.map(function(e) return e.toString() + "\n"));
		
		var validate = if(cls.isInterface) [] else [{
			pos: Context.currentPos(),
			name: 'validate',
			meta: null,
			kind: FFun({
				ret: macro : Array<String>,
				params: null,
				expr: {expr: EBlock(dataValidationExpressions), pos: Context.currentPos()},
				args: [{
					value: null,
					type: macro : Dynamic,
					opt: false,
					name: 'data'
				}]
			}),
			doc: null,
			access: [APublic, AStatic]
		}];

		return fields.concat(validationFields).concat(validate);
	}
	
	////////////////////////////////////////////////////////////////////////////////
	
	static function ignored(f : Field) {
		return !f.meta.exists(function(m) return m.name == "ignore" || m.name == "exclude");
	}

	static function publicVarOrPropOrIncluded(f : Field) {
		if (f.meta.exists(function(m) return m.name == "include")) return true;
		if (f.access.has(AStatic) || !f.access.has(APublic)) return false;
		return switch(f.kind) {
			case FVar(_, _): true;
			case FProp(_, set, _, _): 
				// Need to test accessor method if it starts with set. It can be both "set" and "set_method".
				set == "default" || set == "null" || set.startsWith("set");
			case _: false;
		}
	}

	static function includedFields(fields : Array<Field>, cls : ClassType) : Array<Field> {
		var superClass = cls.superClass == null ? null : cls.superClass.t.get();
			
		var allFields = superClass == null 
			? fields
			: fields.concat(superclassFields(superClass));
			
		// Need to remove the validate meta from the superClass, unless it also implements Dataclass.
		if (superClass != null && !superClass.interfaces.exists(function(i) return i.t.get().name == 'DataClass')) {
			for (field in superClass.fields.get()) {
				field.meta.remove("validate");
			}			
		}
		
			
		return allFields.filter(ignored).filter(publicVarOrPropOrIncluded);
	}
	
	static function superclassFields(cls : ClassType) : Array<Field> {
		return includedFields(cls.fields.get().map(function(f) return {
			pos: f.pos,
			name: f.name,
			meta: f.meta.get(),
			kind: switch f.kind {
				case FVar(read, write):
					function toPropType(access : VarAccess, read : Bool) {
						return switch access {
							case AccNormal: 'default';
							case AccNo: 'null';
							case AccNever: 'never';
							case AccCall: (read ? 'get_' : 'set_') + f.name; // Need to append accessor method
							case _: Context.error("Unsupported field for DataClass inheritance.", f.pos);
						}
					}
					var get = toPropType(read, true);
					var set = toPropType(write, false);
					
					var expr = f.expr() == null ? null : Context.getTypedExpr(f.expr());
					
					FProp(get, set, Context.toComplexType(f.type), expr);
				
				case _: null;
			},
			doc: f.doc,
			access: f.isPublic ? [APublic] : []
		}), cls);
	}
}
#end