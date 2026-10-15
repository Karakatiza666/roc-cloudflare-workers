import Io
import Secret

## Vars and secrets. One sync `call!` each, no wait.
Env :: [].{
	secret! : Str => Try(Secret, [MissingEnv(Str)])
	secret! = |name| match Io.run!(Io.typed(["env.secret", name], |_| BadData(""))) {
		Ok(text) => Ok(Secret.from_str(text))
		Err(_) => Err(MissingEnv(name))
	}
}
