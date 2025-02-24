use std::{fs, env};

use crate::config::ProcTmuxConfig;

pub fn parse_config_from_args()-> Result<ProcTmuxConfig, Box<dyn std::error::Error>>  {
    let args: Vec<String> = env::args().collect();
    let mut config_file = "proctmux.yml".to_string();
    if args.len() >= 2 {
        config_file = args[1].to_string();
    }
    let config_file = fs::File::open(config_file).unwrap();
    let proctmux_config: ProcTmuxConfig = serde_yaml::from_reader(config_file)?;
    Ok(proctmux_config)
}
